use strict;
use warnings;
use Test::More;
use Urume::HostAgent;
use Urume::Storage;
use Try::Tiny;
use Test::SharedFork;
use Test::TCP;
use t::Util;
use Capture::Tiny ':all';

my $redis_server = t::Util->redis_server;
my $config = t::Util->config;

my $pid = fork();
if ($pid) {
    # parent
    my $redis = Redis->new( $redis_server->connect_info );
    my $storage = Urume::Storage->new(
        redis  => $redis,
        config => $config,
    );
    $storage->init;
    isa_ok $storage, "Urume::Storage";
    ok $storage->register_vm(
        name => "testvm",
        host => "localhost",
        base => "centos6",
    );
    sleep 1;
    $storage->_test_vm( name => "testvm" );

    waitpid($pid, 0);
}
else {
    my $agent = Urume::HostAgent->new({
        redis    => { $redis_server->connect_info },
        endpoint => "http://127.0.0.1:9999",
        host     => "localhost",
    });
    isa_ok $agent => "Urume::HostAgent";

    my $stderr = capture_stderr {
        $agent->wait_for_events(2);
    };
    note $stderr;
    like $stderr => qr/ok test: testvm/;
}

done_testing;
