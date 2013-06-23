# -*- mode:perl -*-
use strict;
use warnings;
use Test::More;
use Test::RedisServer;
use Urume::Storage;
use Redis;
use Net::CIDR::Lite;
use Try::Tiny;
use t::Util;

my $redis_server = t::Util->redis_server;
my $redis = Redis->new( $redis_server->connect_info );

my $storage = Urume::Storage->new(
    redis  => $redis,
    config => t::Util->config,
);
isa_ok $storage, "Urume::Storage";

my %id;
subtest "generate_new_id" => sub {
    for ( 1 .. 100 ) {
        my $i = $storage->generate_new_id;
        ok $i;
        ok !defined $id{$i};
        $id{$i} = 1;
    }
};

my %mac;
subtest "generate_mac_addr" => sub {
    for my $id ( sort keys %id ) {
        my $mac = $storage->generate_mac_addr($id);
        like $mac, qr/^52:54:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$/;
        ok !defined $mac{$mac};
        $mac{$mac} = 1;
    }
};

subtest "init" => sub {
    ok $storage->init;
};

subtest "get_ip_addr_from_pool" => sub {
    my $cidr = Net::CIDR::Lite->new("192.168.0.64/26");
    for ( 1 .. 64 ) {
        my $addr = $storage->get_ip_addr_from_pool;
        ok $cidr->find($addr);
    }
    try {
        my $addr = $storage->get_ip_addr_from_pool;
    }
    catch {
        my $e = $_;
        ok $e;
    };
};

subtest "release_ip_addr" => sub {
    ok $storage->release_ip_addr("192.168.0.100");
    ok $storage->release_ip_addr("192.168.0.101");
    ok $storage->release_ip_addr("192.168.0.102");
    for ( 1 .. 3 ) {
        my $addr = $storage->get_ip_addr_from_pool;
        like $addr, qr/^192\.168\.0\.10[012]$/;
    }
    try {
        my $addr = $storage->get_ip_addr_from_pool();
    }
    catch {
        my $e = $_;
        ok $e;
    };
};

subtest "re init" => sub {
    ok $storage->init;
    ok $storage->get_ip_addr_from_pool();
};

subtest "vm" => sub {
    my $vm = $storage->register_vm(
        name => "testvm",
        host => "host01",
        base => "sl6",
    );
    isa_ok $vm, "HASH";
    is $vm->{name} => "testvm";
    ok $vm->{id};
    my $cidr = Net::CIDR::Lite->new("192.168.0.64/26");
    ok $cidr->find($vm->{ip_addr});
    like $vm->{mac_addr}, qr/^52:54:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$/;

    is_deeply [ $storage->list_vm ] => [ $vm ];

    my $vm_n = $storage->get_vm( name => "testvm" );
    is_deeply $vm_n => $vm;

    my $vm_i = $storage->get_vm( ip_addr => $vm->{ip_addr} );
    is_deeply $vm_i => $vm;

    ok $storage->remove_vm( name => "testvm" );

    ok !$storage->get_vm( name => "testvm" );
    ok !$storage->get_vm( ip_addr => $vm->{ip_addr} );

    is_deeply [ $storage->list_vm ] => [];
};

subtest "keyserver" => sub {
    my $vm = $storage->register_vm(
        name => "testvm2",
        host => "host01",
        base => "sl6",
    );
    my $ip = $vm->{ip_addr};

    ok $storage->register_public_key(
        name => "testvm2",
        key  => "ssh-rsa dummy1\nssh-rsa dummy2",
    );
    my $key = $storage->retrieve_public_key( name => "testvm2" );
    is $key => "ssh-rsa dummy1\nssh-rsa dummy2";

    $key = $storage->retrieve_public_key( ip_addr => $ip );
    is $key => "ssh-rsa dummy1\nssh-rsa dummy2";

    ok ! $storage->retrieve_public_key( name => "testvm3" );
};

subtest "user_data" => sub {
    my $vm = $storage->register_vm(
        name => "testvm3",
        host => "host01",
        base => "sl6",
    );
    my $ip = $vm->{ip_addr};

    ok $storage->register_user_data(
        name => "testvm3",
        data => "#!/bin/sh\necho 'hello world'\n",
    );
    my $data = $storage->retrieve_user_data( name => "testvm3" );
    is $data => "#!/bin/sh\necho 'hello world'\n";

    $data = $storage->retrieve_user_data( ip_addr => $ip );
    is $data => "#!/bin/sh\necho 'hello world'\n";

    ok ! $storage->retrieve_user_data( name => "testvm4" );
};

subtest "vm name" => sub {
    my $vm;
    try {
        $vm = $storage->register_vm(
            name => "test-vm",
            host => "host01",
            base => "sl6",
        );
    }
    catch {
        my $e = $_;
        note "catch: $e";
    };

    isa_ok $vm, "HASH";
};

subtest "vm dup register" => sub {
    my $vm;
    try {
        $vm = $storage->register_vm(
            name => "test-vm",
            host => "host01",
            base => "sl6",
        );
    }
    catch {
        my $e = $_;
        note "catch: $e";
        like $e => qr/exists/;
    };
};

done_testing;
