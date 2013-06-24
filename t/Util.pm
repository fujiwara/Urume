package t::Util;

use strict;
use warnings;
use Test::More;
use Redis;
use Test::RedisServer;
use Plack::Test;
use Net::CIDR::Lite;
use Exporter 'import';
use Log::Minimal ();
our @EXPORT_OK = qw/ subtest_psgi /;

our $redis_server;

sub redis_server {
    eval {
        $redis_server = Test::RedisServer->new;
    } or fail('redis-server is required to this test');
    $redis_server;
}

sub config {
    +{
        mac_address_base => 13128,
        dhcp => {
            range      => ["192.168.0.64", "192.168.0.127"],
            lease_time => 2,
        },
        hosts => ["host01", "host02", "localhost"],
        base_images => ["centos6", "sl6"],
    };
}

sub cidr {
    Net::CIDR::Lite->new("192.168.0.64/26");
}

sub subtest_psgi {
    my ($name, $app, $client) = @_;
    subtest $name, sub {
        Plack::Test::test_psgi( app => $app, client => $client );
    };
}

1;
