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

    my @args
        = map { $_ => scalar $c->req->param($_) }
            qw/ name host base /;
    my $vm = $self->storage->register_vm(@args);

    $self->storage->clone_vm( name => $vm->{name} );

    if ( my $key = $c->req->param("public_key") ) {
        $self->storage->register_public_key(
            name => $vm->{name},
            key  => $key,
        );
    }
    if ( $c->req->param("start") ) {
        $self->storage->start_vm( name => $vm->{name} );
    }

    $c->render_json($vm);
};

get '/vm/info/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name );
    $c->halt(404) unless $vm;

    $c->render_json($vm);
};

post '/vm/info/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name );
    $c->halt(404) unless $vm;

    $self->storage->set_vm_status(
        $name => $c->req->param("active") ? 1 : 0,
    );

    $vm = $self->storage->get_vm( name => $name );
    $c->render_json($vm);
};

post '/vm/remove/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name = $c->args->{name};

    my $vm = $self->storage->get_vm( name => $name );
    $c->halt(404) unless $vm;

    if ( $vm->{status} == Urume::VM_STATUS_RUNNING ) {
        warnf "Can't remove active VM: %s status: %d", $vm->{name}, $vm->{status};
        $c->halt(400);
    }
    else {
        $self->storage->remove( name => $name );
    }
};


post '/vm/:method/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;
    my $name   = $c->args->{name};
    my $method = sprintf "%s_vm", $c->args->{method};

    my $vm = $self->storage->get_vm( name => $name );
    $c->halt(404) unless $vm;

    if ($self->storage->can($method)) {
        $self->storage->$method( name => $name );
    }
    else {
        $c->halt(404);
    }
};

get '/public_key' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $ip_addr = $c->req->address;
    my $key    = $self->storage->retrieve_public_key( ip_addr => $ip_addr );
    $c->halt(404) unless $key;

    $c->res->content_type("text/plain; charset=utf8");
    $c->res->body($key);
    $c->res;
};

get '/public_key/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $key = $self->storage->retrieve_public_key( name => $c->args->{name} );
    $c->halt(404) unless $key;

    $c->res->content_type("text/plain; charset=utf8");
    $c->res->body($key);
    $c->res;
};

post '/public_key/:name' => [qw/auto/] => sub {
    my ( $self, $c )  = @_;

    my $key = $c->req->param('key');
    $c->halt(400) unless defined $key;

    infof "register public key %s: %s", $c->args->{name}, $key;
    $self->storage->register_public_key(
        name => $c->args->{name},
        key  => $key,
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

1;

