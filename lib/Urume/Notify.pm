package Urume::Notify;

use strict;
use warnings;
use 5.12.0;
use EV::Hiredis;
use AE;
use Plack::Request;
use JSON;
use Log::Minimal;

my $Timeout = 900;

sub psgi_app {
    my $class  = shift;
    my $config = shift;

    sub {
        my $env = shift;
        my $req = Plack::Request->new($env);

        my $name  = (split "/", $req->path_info)[-1];
        my $redis = EV::Hiredis->new(%{ $config->{redis} });

        debugf "subscribe: %s", $name;
        my $cv = AE::cv;
        my $channel = "vm_events_ch:$name";
        $redis->subscribe(
            $channel => sub {
                my ($r) = @_;
                return unless $r;
                if ( $r->[0] eq "message" ) {
                    debugf "message: %s", $r->[2];
                    $cv->send( $r->[2] );
                }
                elsif ( $r->[0] eq "unsubscribe" ) {
                    $redis->disconnect;
                }
            }
        );
        my $w = AE::timer $Timeout, 0, sub {
            infof "timeout notify channel: %s, client: %s ua: %s",
                $channel,
                $req->address,
                $req->user_agent;
            $redis->unsubscribe($channel, sub { });
            undef $redis;
        };
        return sub {
            my $respond = shift;
            $cv->cb(
                sub {
                    my $message = $_[0]->recv;
                    undef $w;
                    $respond->([
                        200,
                        [ "Content-Type" => "application/json" ],
                        [ encode_json({ message => $message }) ],
                    ]);
                    $redis->unsubscribe($channel, sub { });
                }
            );
        };
    };
}

1;
