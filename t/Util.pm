package t::Util;

use strict;
use warnings;
use Test::More;
use Redis;
use Test::RedisServer;

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
            range => ["192.168.0.64", "192.168.0.127"],
        },
        hosts => ["host01", "host02", "localhost"],
        base_images => ["centos6", "sl6"],
    };
}


1;
