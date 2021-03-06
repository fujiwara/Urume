package Urume::Storage;

use strict;
use warnings;
use 5.12.0;
use Mouse;
use Urume;
use Log::Minimal;
use Net::IP;
use Carp;
use JSON;
use List::MoreUtils qw/ any /;
use Redis;
use Try::Tiny;
use List::Util qw/ shuffle first /;

my $NameRegex = qr/\A[a-zA-Z0-9][a-zA-Z0-9\-]+\z/;

has config => (
    is  => "rw",
    isa => "HashRef",
);

has redis => (
    is  => "rw",
    isa => "Redis",
    lazy => 1,
    default => sub {
        my $self = shift;
        debugf "connect to redis: %s", ddf $self->config->{redis};
        Redis->new(%{ $self->config->{redis} });
    },
);

has renderer => (
    is  => "rw",
    isa => "CodeRef",
);

sub generate_new_id {
    my $self = shift;
    $self->redis->incr("vm_serial");
}

sub generate_mac_addr {
    my $self = shift;
    my $id   = shift;
    $id += $self->config->{mac_address_base} || 0;
    my $sub = sprintf("%06s", (sprintf "%x", $id));
    $sub =~ s/(..)(..)(..)/$1:$2:$3/;
    lc "52:54:00:$sub";
}

sub init {
    my $self = shift;

    my $range
        = sprintf "%s - %s",
          $self->config->{dhcp}->{range}->[0],
          $self->config->{dhcp}->{range}->[1],
    ;
    my $ip = Net::IP->new($range)
        || die "invalid range: $range";
    my @ips;
    do {
        push @ips, $ip->ip;
    } while (++$ip);
    my $redis = $self->redis;
    $redis->multi;
    $redis->del("ip_addr_pool");
    $redis->del("leased_ip_addr");
    $redis->sadd("ip_addr_pool" => @ips);
    $redis->exec;
}

sub get_ip_addr_from_pool {
    my $self = shift;
    my %args = @_;

    my $redis = $self->redis;
    my $ip;
    my @locked;
    try {
        while (1) {
            $ip = $redis->spop("ip_addr_pool") || croak("no ip_addr in pool");
            if ( $redis->get("locked_ip_addr:$ip") ) {
                push @locked, $ip;
                next;
            }
            last;
        }
    }
    catch {
        my $e = $_;
        croak $e;
    }
    finally {
        $redis->sadd("ip_addr_pool", @locked) if @locked;
    };
    $redis->hset("leased_ip_addr", $ip => $args{to} // "");

    return $ip;
}

sub release_ip_addr {
    my $self = shift;
    my $ip   = shift;

    my $redis = $self->redis;
    $redis->multi;
    $redis->hdel("leased_ip_addr", $ip);

    # lease_time が経過するまでは再利用されないようにlockしておく
    $redis->set("locked_ip_addr:$ip" => "locked");
    $redis->expire(
        "locked_ip_addr:$ip",
        $self->config->{dhcp}->{lease_time} || 0
    );
    $redis->sadd("ip_addr_pool", $ip);
    $redis->exec;
}

sub list_vm {
    my $self = shift;
    my $redis = $self->redis;
    my @vmname = $redis->keys("vm:*")
        or return;
    my @vm = sort { $a->{id} <=> $b->{id} }
             map { decode_json $_ }
             $redis->mget( $redis->keys("vm:*") );
    for my $vm (@vm) {
        $vm->{status}     = $redis->get("vm_status:$vm->{name}");
        $vm->{public_key} = $redis->get("public_key:$vm->{name}");
        my $port_map = $redis->get("port_map:$vm->{name}");
        $vm->{port_map} = $port_map if defined $port_map;
    }
    @vm;
}

sub get_vm {
    my $self = shift;
    my %args = @_;
    my $redis = $self->redis;
    my $vm_str;
    if ( my $name = $args{name} ) {
        croak "invalid name" if $name !~ $NameRegex;
        $vm_str = $redis->get("vm:$name");
    }
    elsif ( $args{ip_addr} ) {
        my $name = $redis->hget("leased_ip_addr", $args{ip_addr});
        $vm_str = $redis->get("vm:$name") if defined $name;
    }
    return unless defined $vm_str;

    my $vm = decode_json($vm_str);
    $vm->{status}     = $redis->get("vm_status:$vm->{name}");
    $vm->{public_key} = $redis->get("public_key:$vm->{name}");
    my $port_map = $redis->get("port_map:$vm->{name}");
    $vm->{port_map}   = $port_map if defined $port_map;
    $vm;
}

sub set_vm_status {
    my $self   = shift;
    my $name   = shift;
    my $status = shift;

    my $key = "vm_status:$name";
    my $redis = $self->redis;
    $redis->multi;
    $redis->set($key => $status);
    $redis->expire($key, Urume::VM_STATUS_EXPIRES);
    $redis->exec;
}

sub register_vm {
    my $self = shift;
    my %args = @_;

    my $vm = $self->get_vm(@_);
    croak "already exists" if $vm;

    my $name = $args{name};
    croak "invalid name" if $name !~ $NameRegex;

    my $base = $args{base};
    my $host = $args{host};

    my @bases = @{ $self->config->{base_images} };
    if ( grep { $_ eq $base } @bases ) {
        # config にある base を使用する場合
        if (!$host) {
            # host未指定ならランダム選択
            $host = first { 1 } shuffle @{ $self->config->{hosts} };
        }
        else {
            # host指定ならconfigにあるかどうか
            my @hosts = grep { $_ eq $host } @{ $self->config->{hosts} };
            croak "invalid host"
                unless @hosts;
        }
    }
    else {
        # configにないbaseの場合は既存VMでofflineのものに含まれているか
        my ($base_vm) = grep { $_->{name} eq $base && $_->{status} == Urume::VM_STATUS_STOP } $self->list_vm;
        if ($base_vm) {
            # 既存VMから作る場合は host は同じもの
            $host = $base_vm->{host};
        }
        else {
            croak "invalid base";
        }
    }

    my $id  = $self->generate_new_id;
    my $mac = $self->generate_mac_addr($id);
    my $ip  = $self->get_ip_addr_from_pool( to => $name );

    $self->redis->set("vm:$name" => encode_json({
        id       => $id,
        name     => $name,
        ip_addr  => $ip,
        mac_addr => $mac,
        host     => $host,
        base     => $base,
    }));

    return $self->get_vm( name => $name );
}

sub remove_vm {
    my $self = shift;
    my %args = @_;

    my $vm = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};
    $self->release_ip_addr( $vm->{ip_addr} );
    $self->redis->del("vm:$name");
    $self->redis->del("vm_status:$name");
    $self->redis->del("public_key:$name");
    $self->redis->del("user_data:$name");
    $self->redis->del("port_map:$name");

    $self->redis->publish(
        "host_events_ch:$host" => "remove\t$name"
    );
    $self->publish_dnsmasq_conf;
    1;
}

sub start_vm {
    my $self = shift;

    my $vm   = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};

    $self->redis->publish(
        "host_events_ch:$host" => "start\t$name"
    );
}

sub stop_vm {
    my $self = shift;

    my $vm   = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};

    $self->redis->publish(
        "host_events_ch:$host" => "stop\t$name"
    );
}

sub force_stop_vm {
    my $self = shift;

    my $vm   = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};

    $self->redis->publish(
        "host_events_ch:$host" => "force_stop\t$name"
    );
}

sub clone_vm {
    my $self = shift;

    my $vm   = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};
    my $base = $vm->{base};
    my $mac  = $vm->{mac_addr};

    $self->redis->publish(
        "host_events_ch:$host" => "clone\t$name\t$base\t$mac"
    );
    $self->publish_dnsmasq_conf;
    1;
}

sub _test_vm {
    my $self = shift;

    my $vm   = $self->get_vm(@_);
    my $name = $vm->{name};
    my $host = $vm->{host};

    $self->redis->publish(
        "host_events_ch:$host" => "_test\t$name"
    );
}

sub register_public_key {
    my $self = shift;
    my %args = @_;
    my $vm   = $self->get_vm(%args);

    $self->redis->set("public_key:$vm->{name}" => $args{key});
}

sub retrieve_public_key {
    my $self = shift;
    my %args = @_;
    my $vm   = $self->get_vm(%args);
    return unless $vm;

    $vm->{public_key};
}

sub register_user_data {
    my $self = shift;
    my %args = @_;
    my $vm   = $self->get_vm(%args);

    $self->redis->set("user_data:$vm->{name}" => $args{data});
}

sub retrieve_user_data {
    my $self = shift;
    my %args = @_;
    my $vm   = $self->get_vm(%args);
    return unless $vm;

    $self->redis->get("user_data:$vm->{name}");
}

sub register_port_map {
    my $self = shift;
    my %args = @_;
    my $vm   = $self->get_vm(%args);
    if ( $args{port} > 0 ) {
        $self->redis->set(
            "port_map:$vm->{name}" => sprintf(
                "%s:%d", $vm->{ip_addr}, $args{port},
            ),
        );
    }
    elsif ( $args{port} == 0 ) {
        $self->redis->del("port_map:$vm->{name}");
    }
}

sub publish_dnsmasq_conf {
    my $self = shift;
    if ( my $code = $self->renderer ) {
        my @vms = $self->list_vm;
        my $conf = $code->('dnsmasq.conf.tx', { vms => \@vms });
        $self->redis->publish(
            dnsmasq_events_ch => $conf,
        );
    }
}

sub publish_vm_event {
    my $self = shift;
    my ($vm, $message) = @_;
    my $name = $vm->{name};
    $self->redis->publish("vm_events_ch:$name" => $message);
}

1;

__END__
