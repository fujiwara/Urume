# -*- mode:perl -*-
use strict;
use warnings;
use Test::More;
use Urume::Web;
use t::Util qw/ subtest_psgi /;
use Plack::Test;
use HTTP::Request::Common;

my $redis_server = t::Util->redis_server;
my $root_dir = ".";
my $config = t::Util->config;
Urume::Web->config($config);
my $app = Urume::Web->psgi($root_dir);

subtest_psgi "/", $app, sub {
    my $cb  = shift;
    my $req = GET "http://localhost/"
    my $res = $cb->($req);
    is $res->code, 200;
};

done_testing;
