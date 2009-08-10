#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Module::Find;
use lib::abs '../lib';
BEGIN {
	setmoduledirs( $INC[0] );
	my @modules = grep { !/^TODO$/ } findallmod 'AnyEvent';
	plan tests => scalar( @modules );
	use_ok $_ for @modules;
};
diag( "Testing AnyEvent::SMTP $AnyEvent::SMTP::VERSION, Perl $], $^X" );
