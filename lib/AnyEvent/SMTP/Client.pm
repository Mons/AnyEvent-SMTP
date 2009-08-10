package AnyEvent::SMTP::Client;

=head1 NAME

AnyEvent::SMTP::Client - Simple asyncronous SMTP Client

=cut

use Carp;
use AnyEvent; BEGIN { AnyEvent::common_sense }
#use strict;
#use warnings;

use base 'Object::Event';

use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::DNS;
use AnyEvent::Util;

use Sys::Hostname;
use Mail::Address;

use AnyEvent::SMTP::Conn;

=head1 SYNOPSIS

    use AnyEvent::SMTP::Client 'sendmail';
    
    sendmail
        from => 'mons@cpan.org',
        to   => 'mons@cpan.org', # SMTP host will be detected from addres by MX record
        data => 'Test message '.time().' '.$$,
        cb   => sub {
            if (my $ok = shift) {
                warn "Successfully sent";
            }
            if (my $err = shift) {
                warn "Failed to send: $err";
            }
        }
    ;

=head1 DESCRIPTION

Asyncronously connect to SMTP server, resolve MX, if needed, then send HELO => MAIL => RCPT => DATA => QUIT and return responce

=head1 FUNCTIONS

=head2 sendmail ... , cb => $cb->(OK,ERR)

Argument names are case insensitive. So, it may be calles as

    sendmail From => ..., To => ..., ...

and as

    sendmail from => ..., to => ..., ...

Arguments description are below

=over 4

=item host => 'smtp.server'

SMTP server to use. Optional. By default will be resolved MX record

=item port => 2525

SMTP server port. Optional. By default = 25

=item helo => 'hostname'

HELO message. Optional. By default = hostname()

=item from => 'mail@addr.ess'

=item to => 'mail@addr.ess'

=item to => [ 'mail@addr.ess', ... ]

=item data => 'Message body'

=item Message => 'Message body'

Message text. For message composing may be used, for ex: L<MIME::Lite>

=item timeout => int

Use timeout during network operations

=item debug => 0 | 1

Enable connection debugging

=item cb => $cb->(OK,ERR)

Callback.

When $args{to} is a single argument:

    OK - latest response from server
    If OK is undef, then something failed, see ERR
    ERR - error response from server

When $args{to} is an array:

    OK - hash of success responces or undef.
    keys are addresses, values are responces

    ERR - hash of error responces.
    keys are addresses, values are responces

See examples

=item cv => AnyEvent->condvar

If passed, used as group callback operand

    sendmail ... cv => $cv, cb => sub { ...; };

is the same as

    $cv->begin;
    sendmail ... cb => sub { ...; $cv->end };

=back

=cut

sub import {
	my $me = shift;
	my $pkg = caller;
	no strict 'refs';
	@_ or return;
	for (@_) {
		if ( $_ eq 'sendmail') {
			*{$pkg.'::'.$_} = \&$_;
		} else {
			croak "$_ is not exported by $me";
		}
	}
}

sub sendmail(%) {
	my %args = @_;
	my @keys = keys %args;
	@args{map lc, @keys} = delete @args{ @keys };
	$args{data} ||= delete $args{message} || delete $args{body};
	$args{helo} ||= hostname();
	$args{port} ||= 25;

	my ($run,$cv,$res,$err);
	$args{cv}->begin if $args{cv};
	$cv = AnyEvent->condvar;
	my $end = sub{
		undef $run;
		undef $cv;
		undef $end;
		$args{cb}( $res, defined $err ? $err : () );
		$args{cv}->end if $args{cv};
		%args = ();
	};
	$cv->begin($end);
	
	($args{from},my @rcpt) = map { $_->address } map { Mail::Address->parse($_) } $args{from},ref $args{to} ? @{$args{to}} : $args{to};
	
	$run = sub {
		my ($host,$port,@to) = @_;
		warn "connecting to $host:$port\n" if $args{debug};
		my ($exc,$con);
		my $cb = sub {
			undef $exc;
			$con and $con->close;
			undef $con;
			if (@rcpt > 1) {
				#warn "multi cb @to: @_";
				if ($_[0]) {
					@$res{@to} = ($_[0])x@to;
				} else {
					@$err{@to} = ($_[1])x@to;
				}
			} else {
				#warn "single cb @to: @_";
				($res,$err) = @_;
			}
			$cv->end;
		};
		$cv->begin;
		tcp_connect $host,$port,sub {
			my $fh = shift
				or return $cb->(undef, "$!");
			$con = AnyEvent::SMTP::Conn->new( fh => $fh, debug => $args{debug}, timeout => $args{timeout} );
			$exc = $con->reg_cb(
				disconnect => sub {
					$con or return;
					$cb->(undef,$_[1]);
				},
			);
			$con->line(ok => 220, cb => sub {
				shift or return $cb->(undef, @_);
				$con->command("HELO $args{helo}", ok => 250, cb => sub {
					shift or return $cb->(undef, @_);
					$con->command("MAIL FROM: <$args{from}>", ok => 250, cb => sub {
						shift or return $cb->(undef, @_);

						my $cv1 = AnyEvent->condvar;
						$cv1->begin(sub {
							undef $cv1;
							$con->command("DATA", ok => 354, cb => sub {
								shift or return $cb->(undef, @_);
								$con->reply("$args{data}");
								$con->command(".", ok => 250, cb => sub {
									my $reply = shift or return $cb->(undef, @_);
									$cb->($reply);
								});
							});
						});

						for ( @to ) {
							$cv1->begin;
							$con->command("RCPT TO: <$_>", ok => 250, cb => sub {
								shift or return $cb->(undef, @_);
								$cv1->end;
							});
						}

						$cv1->end;
					});

				});
			});
		};
		
	};
	
	if ($args{host}) {
		$run->($args{host},$args{port}, @rcpt);
	} else {
		my %domains;
		my $dns = AnyEvent::DNS->new(
			$args{timeout} ? ( timeout => [ $args{timeout} ] ) : ()
		);
		$dns->os_config;
		for (@rcpt) {
			my ($domain) = /^.+\@(.+)$/;
			push @{ $domains{$domain} ||= [] }, $_;
		}
		for my $domain (keys %domains) {
			$cv->begin;
			$dns->resolve( $domain => mx => sub {
				@_ = map $_->[4], sort { $a->[3] <=> $b->[3] } @_;
				warn "MX($domain) = [ @_ ]\n" if $args{debug};
				if (@_) {
					$run->(shift, $args{port}, @{ delete $domains{$domain} });
				} else {
					if (@rcpt > 1) {
						@$err{ @{ $domains{$domain} } } = ( "No MX record for domain $domain" )x@{ $domains{$domain} };
					} else {
						$err = "No MX record for domain $domain";
					}
				}
				$cv->end;
			});
		}
		undef $dns;
	}
	$cv->end;
	defined wantarray
		? AnyEvent::Util::guard { $end->(undef, "Cancelled"); }
		: ();
}

=head1 BUGS

Bug reports are welcome in CPAN's request tracker L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=AnyEvent-SMTP>

=head1 AUTHOR

Mons Anderson, C<< <mons at cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Mons Anderson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
