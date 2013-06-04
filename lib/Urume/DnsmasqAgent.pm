package Urume::DnsmasqAgent;

use strict;
use warnings;
use Log::Minimal;
use IO::File;
use Redis;

our $VERSION = "0.1";

sub new {
    my $class  = shift;
    my $config = shift;

    my $self = {
        redis   => $config->{redis},
        config  => $config->{config} || "/etc/dnsmasq.d/urume.conf",
        restart_command =>
            $config->{restart_command} || "/sbin/service dnsmasq restart",
    };
    infof "%s created: %s", $class, ddf $self;

    $self->{redis} = Redis->new( %{ $config->{redis} });

    bless $self, $class;
}

sub run {
    my $self = shift;

    infof "starting dnsmasqagent";
    my $channel = "dnsmasq_events_ch";
    debugf "subscribe for %s", $channel;

    $self->{redis}->subscribe(
        $channel => sub {
            my $message = shift;
            infof "message arrival: %s", $message;
            open my $fh, ">", $self->{config} or do {
                critf "Can't open %s: %s", $self->{config}, $!;
                return;
            };
            $fh->print($message);
            $fh->close;
            system $self->{restart_command};
        }
    );
    $self->{redis}->wait_for_messages(30) while 1;
}

1;

__END__
