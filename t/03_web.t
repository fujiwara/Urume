# -*- mode:perl -*-
use strict;
use warnings;
use Test::More;
use Urume::Web;
use t::Util qw/ subtest_psgi /;
use Plack::Test;
use HTTP::Request::Common;
use List::MoreUtils qw/ any /;
use JSON;

my $redis_server = t::Util->redis_server;
my $root_dir = ".";
my $config = t::Util->config;
$config->{redis} = { $redis_server->connect_info };
Urume::Web->config($config);
my $app  = Urume::Web->psgi($root_dir);
my $cidr = t::Util->cidr;

subtest_psgi "/", $app, sub {
    my $cb  = shift;
    my $req = GET "http://localhost/";
    my $res = $cb->($req);
    is $res->code, 200;
};

subtest_psgi "/vm/list", $app, sub {
    my $cb  = shift;
    my $req = GET "http://localhost/vm/list";
    my $res = $cb->($req);
    is $res->code, 200;
    is $res->content_type, "application/json";
    my $json = decode_json($res->content);
    is_deeply $json => [];
};

subtest_psgi "/init", $app, sub {
    my $cb  = shift;
    my $req = POST "http://localhost/init";
    my $res = $cb->($req);
    is $res->code, 200;
};

my $newvm;
subtest_psgi "/vm/register", $app, sub {
    my $cb  = shift;
    my $req = POST "http://localhost/vm/register",
                   [ name       => "testvm",
                     base       => "centos6",
                     public_key => "ssh-rsa AAAAxxxx",
                   ];
    my $res = $cb->($req);
    is $res->code, 201;
    my $vm = decode_json($res->content);
    is $vm->{name} => "testvm";
    is $vm->{base} => "centos6";
    is $vm->{public_key} => "ssh-rsa AAAAxxxx";
    ok exists $vm->{status};
    ok any { $_ eq $vm->{host} } @{$config->{hosts}};
    ok $cidr->find($vm->{ip_addr});
    like $vm->{id}, qr/^\d+$/;
    like $vm->{mac_addr}, qr/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;
    $newvm = $vm;
};

subtest_psgi "vm/(list|info)", $app, sub {
    my $cb  = shift;
    my $req = GET "http://localhost/vm/info/xxxx";
    my $res = $cb->($req);
    is $res->code, 404;

    $req = GET "http://localhost/vm/info/testvm";
    $res = $cb->($req);
    is $res->code, 200;
    my $vm = decode_json($res->content);
    is_deeply $vm => $newvm;

    $req = GET "http://localhost/vm/list";
    $res = $cb->($req);
    is $res->code, 200;
    my $vms = decode_json($res->content);
    is_deeply $vms => [ $newvm ];
};


done_testing;
