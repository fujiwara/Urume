use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Urume::Web;
use Urume::Notify;

my $root_dir   = File::Basename::dirname(__FILE__);
my $config     = Urume::Web->config("config.pl", "config_local.pl");
my $main_app   = Urume::Web->psgi($root_dir);
my $notify_app = Urume::Notify->psgi_app($config);

builder {
    enable 'ReverseProxy';
    enable 'Static',
        path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
        root => $root_dir . '/public';
    mount "/notify", $notify_app;
    mount "/", $main_app;
};
