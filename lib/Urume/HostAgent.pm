package Urume::HostAgent;

use strict;
use warnings;
use Urume;
use Log::Minimal;
use Redis;

our $VERSION = "0.1";

sub new {
    my $class  = shift;
    my $config = shift;

    my $self = {
        redis      => $config->{redis},
        images_dir => $config->{images_dir} || "/var/lib/libvirt/images",
        host       => $config->{host}       || do { my $host = qx{ hostname -s }; chomp $host; $host },
        timeout    => $config->{timeout}    || 30,
    };
    infof "%s created: %s", $class, ddf $self;

    $self->{redis_e} = Redis->new( %{ $config->{redis} });
    $self->{redis_r} = Redis->new( %{ $config->{redis} });

    bless $self, $class;
}

sub run {
    my $self = shift;

    infof "starting hostagent";
    while (1) {
        $self->report_vm_status;
        $self->wait_for_events( $self->{timeout} );
    }
}

sub report_vm_status {
    my $self = shift;

    local $ENV{LANG} = "C";
    my @result = grep { /^ +(\d+|-)/ }qx{virsh list --all};
    my $reported = 0;
    for my $r (@result) {
        $r =~ s/^\s+//;
        my ($id, $name, $state) = split /\s+/, $r;
        my $active = $state eq "running"
                   ? Urume::VM_STATUS_RUNNING
                   : Urume::VM_STATUS_STOP;
        debugf "reporting vm_status %s %s", $name, $active;
        my $res = $self->{redis_r}->set(
            "vm_status:$name" => $active,
        );
        $reported++ if $res;
    }
    $reported;
}

sub wait_for_events {
    my $self = shift;
    my $timeout = shift || $self->{timeout};

    unless ($self->{_subscribed}) {
        my $channel = "host_events_ch:$self->{host}";
        debugf "subscribe for %s", $channel;

        $self->{redis_e}->subscribe(
            $channel => sub {
                my $message = shift;
                debugf "message arrival: %s", $message;
                my ($command, @attr) = split /\t/, $message;
                $self->invoke_command($command, @attr);
                $self->report_vm_status;
            }
        );
        $self->{_subscribed} = 1;
    }

    $self->{redis_e}->wait_for_messages($timeout);
}

sub invoke_command {
    my $self = shift;
    my ($command, @attr) = @_;
    if ( my $method = $self->can("_command_${command}") ) {
        infof "run command:%s attr:%s", $command, ddf \@attr;
        $method->($self, @attr);
    }
    else {
        warnf "not supported command:%s attr:%s", $command, ddf \@attr;
    }
}

sub _command__test {
    my $self = shift;
    my $name = shift;
    infof "ok test: %s", $name;
    1;
}

sub _execute_virsh {
    my $self = shift;
    my ($method, $name) = @_;

    local $ENV{LANG} = "C";
    infof "execute: virsh %s %s", $method, $name;
    my $r = system("virsh", $method, $name);
    if ($r != 0) {
        critf "Can't %s %s: exit status %d", $method, $name, $r;
    }
    $r == 0;
}

sub _command_start {
    my $self = shift;
    my $name = shift;
    $self->_execute_virsh("start", $name);
}

sub _command_stop {
    my $self = shift;
    my $name = shift;
    $self->_execute_virsh("shutdown", $name);
}

sub _command_force_stop {
    my $self = shift;
    my $name = shift;
    $self->_execute_virsh("destroy", $name);
}

sub _command_remove {
    my $self = shift;
    my $name = shift;

    my $file = sprintf "%s/%s.img", $self->{images_dir}, $name;
    unlink $file
        or warnf "Can't unlink image file %s: %s", $file, $!;

    $self->_execute_virsh("undefine", $name);
}

sub _command_halt {
    my $self = shift;
    my $name = shift;
    $self->_execute_virsh("destroy", $name);
}

sub _command_clone {
    my $self = shift;
    my ($name, $base, $mac_addr) = @_;

    local $ENV{LANG} = "C";
    my $file = sprintf "%s/%s.img", $self->{images_dir}, $name;
    my @command = (
        "virt-clone",
        "-o"     => $base,
        "-n"     => $name,
        "--mac"  => $mac_addr,
        "--file" => $file,
    );
    infof "execute: @command";
    my $r = system(@command);
    if ($r != 0) {
        critf "failed: exit status %d", $r;
    }
    $r == 0;
}

1;

__END__
