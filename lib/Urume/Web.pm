package Urume::Web;

use strict;
use warnings;
use utf8;
use Urume;
use Kossy;
use Config::PL ();
use JSON;
use Net::IP;
use Log::Minimal;
use Urume::Storage;

filter 'auto' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        $c->stash->{config} = $self->config;
        my $storage = Urume::Storage->new(
            config   => $self->config,
            renderer => sub {
                my $file = shift;
                my %args = ( @_ && ref $_[0] ) ? %{$_[0]} : @_;
                my %vars = (
                    c     => $c,
                    stash => $c->stash,
                    %args,
                );
                $c->tx->render($file, \%vars);
            },
        );
        $self->storage($storage);
        $app->($self, $c);
    }
};

get '/' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my @vms = $self->storage->list_vm;
    $c->render( 'index.tx', {
        vms => \@vms,
    });
};

get '/dnsmasq.conf' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my @vms = $self->storage->list_vm;
    $c->render( 'dnsmasq.conf.tx', {
        vms => \@vms,
    });
    $c->res->content_type("text/plain; charset=utf8");
    $c->res;
};

post '/vm/register' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my %args
        = map { $_ => scalar $c->req->param($_) }
            qw/ name host base /;
    my $vm = $self->storage->register_vm(%args);

    $self->storage->clone_vm( name => $vm->{name} );

    if ( my $key = $c->req->param("public_key") ) {
        $self->storage->register_public_key(
            name => $vm->{name},
            key  => $key,
        );
    }
    if ( my $data = $c->req->param("user_data") ) {
        $self->storage->register_user_data(
            name => $vm->{name},
            data => $data,
        );
    }

    $self->storage->start_vm( name => $vm->{name} );

    $vm = $self->storage->get_vm( name => $vm->{name} );
    $c->render_json($vm);
    $c->res->status(201);
    $c->res;
};

get '/vm/list' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my @vm = $self->storage->list_vm();
    $c->render_json(\@vm);
};

get '/vm/info/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name )
        or return $self->error( $c => 404, "vm not found" );

    $c->render_json($vm);
};

post '/vm/info/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name )
        or $self->error( $c => 404, "vm not found" );

    $self->storage->set_vm_status(
        $name => $c->req->param("active") ? 1 : 0,
    );

    $vm = $self->storage->get_vm( name => $name );
    $c->render_json($vm);
};

post '/vm/remove/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name )
        or $self->error( $c, 404, "vm not found" );

    if ( $vm->{status} == Urume::VM_STATUS_RUNNING ) {
        warnf "Can't remove active VM: %s status: %d", $vm->{name}, $vm->{status};
        return $self->error( $c, 400, "vm is running" );
    }
    else {
        $self->storage->remove_vm( name => $name );
    }
    $c->render_json({ ok => JSON::true });
};


post '/vm/:method/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name   = $c->args->{name};
    my $method = sprintf "%s_vm", $c->args->{method};

    my $vm = $self->storage->get_vm( name => $name )
        or return $self->error( $c, 404, "vm not found" );

    if ($self->storage->can($method)) {
        $self->storage->$method( name => $name );
    }
    else {
        return $self->error( $c, 404, "method not found" );
    }
    $c->render_json({ ok => JSON::true });
};

get '/public_key' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $ip_addr = $c->req->address;
    my $key     = $self->storage->retrieve_public_key( ip_addr => $ip_addr )
        or return $self->error( $c, 404, "public_key not found" );

    $c->res->content_type("text/plain; charset=utf8");
    $c->res->body($key);
    $c->res;
};

get '/public_key/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $key = $self->storage->retrieve_public_key( name => $c->args->{name} );

    $c->res->content_type("text/plain");
    if (defined $key) {
        $c->res->body($key);
    }
    else {
        $c->res->status(404);
        $c->res->body("");
    }
    $c->res;
};

post '/public_key/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $key = $c->req->param('public_key')
        or return $self->error( $c, 400, "param public_key is required" );

    infof "register public key %s: %s", $c->args->{name}, $key;
    $self->storage->register_public_key(
        name => $c->args->{name},
        key  => $key,
    );
    $c->render_json({ ok => JSON::true });
};

get '/user_data' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $ip_addr = $c->req->address;
    my $data = $self->storage->retrieve_user_data( ip_addr => $ip_addr );

    $c->res->content_type("text/plain");
    if (defined $data) {
        $c->res->body($data);
    }
    else {
        $c->res->status(404);
        $c->res->body("## user_data is not found\n");
    }
    $c->res;
};

get '/user_data/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $data = $self->storage->retrieve_user_data( name => $c->args->{name} );

    $c->res->content_type("text/plain");
    if (defined $data) {
        $c->res->body($data);
    }
    else {
        $c->res->status(404);
        $c->res->body("## user_data is not found\n");
    }
    $c->res;
};

post '/user_data/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $data = $c->req->param('user_data')
        or return $self->error( $c, 400, "param user_data is required" );

    $self->storage->register_user_data(
        name => $c->args->{name},
        data => $data,
    );
    $c->render_json({ ok => JSON::true });
};

post '/init' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    $self->storage->init;
    $c->render_json({ ok => JSON::true });
};

get '/config' => sub {
    my ( $self, $c )  = @_;
    $c->render_json( $self->config );
};

our $Config = {};
sub config {
    my $class = shift;
    my @args  = @_;
    return $Config unless @args;

    for my $cfg ( @args ) {
        if (ref $cfg && ref $cfg eq "HASH") {
            $Config = { %$Config, %$cfg };
        }
        else {
            $Config = { %$Config, %{ Config::PL::config_do($cfg) } };
        }
    }
    $Config;
}

sub storage {
    my $self = shift;
    $self->{_storage} = $_[0] if @_;
    $self->{_storage};
}

sub error {
    my $self = shift;
    my ($c, $code, $message) = @_;
    $c->render_json({ ok => JSON::false, message => $message });
    $c->res->status($code);
    $c->res;
}

1;

