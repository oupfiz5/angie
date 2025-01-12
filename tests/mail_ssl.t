#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for mail ssl module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::IMAP;
use Test::Nginx::POP3;
use Test::Nginx::SMTP;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval {
	require Net::SSLeay;
	Net::SSLeay::load_error_strings();
	Net::SSLeay::SSLeay_add_ssl_algorithms();
	Net::SSLeay::randomize();
};
plan(skip_all => 'Net::SSLeay not installed') if $@;

eval { exists &Net::SSLeay::P_alpn_selected or die; };
plan(skip_all => 'Net::SSLeay with OpenSSL ALPN support required') if $@;

my $t = Test::Nginx->new()->has(qw/mail mail_ssl imap pop3 smtp/)
	->has_daemon('openssl')->plan(18);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    ssl_password_file password;

    auth_http  http://127.0.0.1:8080;	# unused

    server {
        listen             127.0.0.1:8143;
        listen             127.0.0.1:8145 ssl;
        protocol           imap;
    }

    server {
        listen             127.0.0.1:8148;
        protocol           imap;

        # Special case for enabled "ssl" directive.

        ssl on;

        ssl_certificate_key inherits.key;
        ssl_certificate inherits.crt;
    }

    server {
        listen             127.0.0.1:8149;
        protocol           imap;

        starttls           on;
    }

    server {
        listen             127.0.0.1:8150;
        protocol           imap;

        starttls           only;
    }

    server {
        listen             127.0.0.1:8151;
        protocol           pop3;

        starttls           on;
    }

    server {
        listen             127.0.0.1:8152;
        protocol           pop3;

        starttls           only;
    }

    server {
        listen             127.0.0.1:8153;
        protocol           smtp;

        starttls           on;
    }

    server {
        listen             127.0.0.1:8154;
        protocol           smtp;

        starttls           only;
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost', 'inherits') {
	system("openssl genrsa -out $d/$name.key -passout pass:localhost "
		. "-aes128 2048 >>$d/openssl.out 2>&1") == 0
		or die "Can't create private key: $!\n";
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt "
		. "-key $d/$name.key -passin pass:localhost"
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

my $ctx = Net::SSLeay::CTX_new() or die("Failed to create SSL_CTX $!");
$t->write_file('password', 'localhost');

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

###############################################################################

my ($s, $ssl);

# simple tests to ensure that nothing broke with ssl_password_file directive

$s = Test::Nginx::IMAP->new();
$s->ok('greeting');

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'login');

# ssl_certificate inheritance

($s, $ssl) = get_ssl_socket(8145);
like(Net::SSLeay::dump_peer_certificate($ssl), qr/CN=localhost/, 'CN');

($s, $ssl) = get_ssl_socket(8148);
like(Net::SSLeay::dump_peer_certificate($ssl), qr/CN=inherits/, 'CN inner');

# alpn

ok(get_ssl_socket(8148, ['imap']), 'alpn');

SKIP: {
$t->{_configure_args} =~ /LibreSSL ([\d\.]+)/;
skip 'LibreSSL too old', 1 if defined $1 and $1 lt '3.4.0';
$t->{_configure_args} =~ /OpenSSL ([\d\.]+)/;
skip 'OpenSSL too old', 1 if defined $1 and $1 lt '1.1.0';

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.21.4');

ok(!get_ssl_socket(8148, ['unknown']), 'alpn rejected');

}

}

# starttls imap

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8149));
$s->read();

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'imap auth before startls on');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8149));
$s->read();

$s->send('1 STARTTLS');
$s->ok('imap starttls on');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8150));
$s->read();

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/^\S+ BAD/, 'imap auth before startls only');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8150));
$s->read();

$s->send('1 STARTTLS');
$s->ok('imap starttls only');

# starttls pop3

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8151));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'pop3 auth before startls on');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8151));
$s->read();

$s->send('STLS');
$s->ok('pop3 starttls on');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8152));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/^-ERR/, 'pop3 auth before startls only');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8152));
$s->read();

$s->send('STLS');
$s->ok('pop3 starttls only');

# starttls smtp

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8153));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/^334 VXNlcm5hbWU6/, 'smtp auth before startls on');

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8153));
$s->read();

$s->send('STARTTLS');
$s->ok('smtp starttls on');

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8154));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/^5.. /, 'smtp auth before startls only');

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8154));
$s->read();

$s->send('STARTTLS');
$s->ok('smtp starttls only');

###############################################################################

sub get_ssl_socket {
	my ($port, $alpn) = @_;

	my $s = IO::Socket::INET->new('127.0.0.1:' . port($port));
	my $ssl = Net::SSLeay::new($ctx) or die("Failed to create SSL $!");
	Net::SSLeay::set_alpn_protos($ssl, $alpn) if defined $alpn;
	Net::SSLeay::set_fd($ssl, fileno($s));
	Net::SSLeay::connect($ssl) == 1 or return;
	return ($s, $ssl);
}

###############################################################################
