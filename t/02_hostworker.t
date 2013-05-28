use strict;
use warnings;
use Test::More;
use Test::RedisServer;
use Urume::Storage;
use Redis;
use Net::CIDR::Lite;
use Try::Tiny;
use t::Util;

my $redis  = t::Util->redis_client;
my $config = t::Util->config;

my $storage = Urume::Storage->new(
    redis  => $redis,
    config => $config,
);
isa_ok $storage, "Urume::Storage";

done_testing;
