requires 'perl', '5.008001';
requires 'Redis';
requires 'Kossy';
requires 'Config::PL';
requires 'Proclet';
requires 'Net::IP';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Net::CIDR::Lite';
    requires 'Test::SharedFork';
    requires 'Test::RedisServer';
};
