+{
    dns => {
        domain  => "localdomain",
        servers => [ "127.0.0.1", "8.8.8.8", "8.8.4.4" ],
    },
    server => {
        dns_name => "urume-server",
        ip_addr  => "169.254.169.254",
    },
    mac_address_base => 0,
    base_images      => [],
    hosts            => [],
};
