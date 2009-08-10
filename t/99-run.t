#!/usr/bin/env perl


use strict;
use warnings;
use AnyEvent;
use lib::abs '../lib';
use Test::More;
BEGIN {
	eval { require Test::SMTP;1 } or plan skil_all => 'Test::SMTP required';
}

our $port = 1024 + $$  % (65535-1024) ;
$SIG{INT} = $SIG{TERM} = sub {exit 1};

our $child;
unless($child = fork) {

    use AnyEvent::SMTP::Server 'smtp_server';
    use Data::Dumper;

    my $cv = AnyEvent->condvar;

    smtp_server undef, $port, sub {
        warn "MAIL=".Dumper shift;
    };

    $cv->recv;
    exit 0;
} else {
    sleep 1;
}

plan tests => 13;

SKIP:
for (['S1', Host => 'localhost:'.$port, AutoHello => 1]) {
	my $n = $_->[0];
	my $client = Test::SMTP->connect_ok(@$_) or skip 'Not connected',12;
	#$client->auth_ko(1,2,3,'auth');
	$client->mail_from_ok('mons@rambler-co.ru', 'Mail from');
	$client->rcpt_to_ok('mons@rambler-co.ru', 'Rcpt to');
	$client->rset_ok('Rset');

	$client->mail_from_ok('mons@rambler-co.ru', 'Mail from');
	$client->rcpt_to_ok('mons@rambler-co.ru', 'Rcpt to');
	$client->rcpt_to_ok('makc@rambler-co.ru', 'Rcpt to');
	$client->data_ok('Data');

	$client->mail_from_ok('mons@rambler-co.ru', 'Mail from');
	$client->rcpt_to_ok('mons@rambler-co.ru', 'Rcpt to');
	$client->rcpt_to_ok('makc@rambler-co.ru', 'Rcpt to');
	$client->data_ok('Data');

	$client->quit_ok('Quit OK');
}

END {
    $child and kill TERM => $child;
}
