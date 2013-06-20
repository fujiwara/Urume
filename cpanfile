requires 'perl', '5.008001';
requires 'Plack';
requires 'Redis';
requires 'Kossy';
requires 'Config::PL';
requires 'Proclet';
requires 'Net::IP';
requires 'LWP::UserAgent';
requires 'HTTP::Request::Common';
requires 'JSON';
requires 'Path::Class';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Net::CIDR::Lite';
    requires 'Test::SharedFork';
    requires 'Test::RedisServer';
};
