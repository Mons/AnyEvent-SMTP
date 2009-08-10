package AnyEvent::SMTP::Server;

=head1 NAME

AnyEvent::SMTP::Server - Simple asyncronous SMTP Server

=cut

use Carp;
use AnyEvent; BEGIN { AnyEvent::common_sense }
#use strict;
#use warnings;

use base 'Object::Event';

use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Util;

use Sys::Hostname;
use Mail::Address;

use AnyEvent::SMTP::Conn;

our %CMD = map { $_ => 1 } qw( HELO EHLO MAIL RCPT QUIT DATA EXPN VRFY NOOP HELP RSET );

=head1 SYNOPSIS

    use AnyEvent::SMTP::Server 'smtp_server';

    smtp_server undef, 2525, sub {
        my $mail = shift;
        warn "Received mail from $mail->{from} to $mail->{to}\n$mail->{data}\n";
    };
    
    # or
    
    use AnyEvent::SMTP::Server;
    
    my $server = AnyEvent::SMTP::Server->new( port => 2525 );

    $server->reg_cb(
        client => sub {
            my ($s,$con) = @_;
            warn "Client from $con->{host}:$con->{port} connected\n";
        },
        disconnect => sub {
            my ($s,$con) = @_;
            warn "Client from $con->{host}:$con->{port} gone\n";
        },
        mail => sub {
            my ($s,$mail) = @_;
            warn "Received mail from $mail->{from} to $mail->{to}\n$mail->{data}\n";
        },
    );

    $server->start;
    AnyEvent->condvar->recv;

=head1 DESCRIPTION

Simple asyncronous SMTP server. Authorization not implemented yet. Patches are welcome

=head1 FUNCTIONS

=head2 smtp_server $host, $port, $cb->(MAIL)

=head1 METHODS

=head2 new %args;

=over 4

=item hosthame

Server FQDN

=item host

Address to listen on. by default - undef (0.0.0.0)

=item port

Port to listen on

=back

=head2 start

Creates tcp server and starts to listen

=head2 stop

Closes all opened connections and shutdown server

=head1 EVENTS

=over 4

=item client($connection)

Invoked when client connects

=item disconnect($connection)

Invoked when client disconnects

=item mail($mail)

Invoked when server received complete mail message

    $mail = {
        from => ...,
        to   => [ ... ],
        data => '...',
    };

=back

=cut

sub import {
	my $me = shift;
	my $pkg = caller;
	
	@_ or return;
	for (@_) {
		if ( $_ eq 'smtp_server') {
			*{$pkg.'::'.$_} = \&$_;
		} else {
			croak "$_ is not exported by $me";
		}
	}
}

sub smtp_server {
	my ($host,$port,$cb) = @_;
	my $server = AnyEvent::SMTP::Server->new(
		host => $host,
		port => $port,
	);
	$server->reg_cb(
		mail => sub {
			$cb->($_[1]);
		},
	);
	$server->start;
	defined wantarray
		? AnyEvent::Util::guard { $server->stop; %$server = (); }
		: ()
}

sub new {
	my $pkg = shift;
	my $self = bless { @_ }, $pkg;
	$self->{hostname} = hostname() unless defined $self->{hostname};
	$self->set_exception_cb( sub {
		my ($e, $event, @args) = @_;
		my $con;
		{
			local $::self = $self;
			local $::con;
			local $::event = $event;
			{
				package DB;
				my $i = 0;
				while (my @c = caller(++$i)) {
					#warn "$i. [@DB::args]";
					next if @DB::args < 1;
					last if $DB::args[0] == $::self and $DB::args[1] eq $::event;
				}
				$::con = $DB::args[2];
			}
			$con = $::con;
		}
		if ($con) {
			my $msg = "500 INTERNAL ERROR";
			if ($self->{devel}) {
				$e =~ s{(?:\r?\n)+}{ }sg;
				$e =~ s{\s+$}{}s;
				$msg .= ": ".$e;
			}
			$con->reply($msg);
		}
		warn "exception during $event : $e";
	} );
	$self->reg_cb(
		command => sub {
			my ($s,$con,$com) = @_;
			my ($cmd, @args);
			for ($com) {
				s/^\s+//;s/\s+$//;
				length or last;
				($cmd, @args) = split /\s+/;
				$cmd = uc $cmd;
			}
			if (exists $CMD{$cmd}) {
				$s->handle( $con, $cmd, @args );
			} else {
				warn "$cmd @args";
				$con->reply("500 Learn to type!");
			}
			#warn "Got command @_";
		},
		HELO => sub {
			my ($s,$con,@args) = @_;
			$con->{helo} = "@args";
			$con->{m} = {};
			$con->ok("I'm ready.");
		},
		EHLO => sub {
			my ($s,$con,@args) = @_;
			$con->{helo} = "@args";
			$con->{m} = {};
			$con->ok("Go on.");
		},
		RSET => sub {
			my ($s,$con,@args) = @_;
			$con->{m} = {};
			$con->ok;
		},
		MAIL => sub {
			my ($s,$con,$from,@args) = @_;
			$con->{helo} or return $con->reply("503 Error: send HELO/EHLO first");
			my @addrs = map { $_->address } Mail::Address->parse("@args");
			lc $from eq 'from:' and @addrs == 1 or $con->reply('501 Usage: MAIL FROM: mail addr');
			$con->{m}{from} = $addrs[0];
			$con->ok;
		},
		RCPT => sub {
			my ($s,$con,$to,@args) = @_;
			$con->{m}{from} or return $con->reply("503 Error: need MAIL command");
			my @addrs = map { $_->address } Mail::Address->parse("@args");
			lc $to eq 'to:' and @addrs or $con->reply('501 Usage: RCPT TO: mail addr');
			push @{ $con->{m}{to} ||= [] }, @addrs;
			$con->ok;
		},
		DATA => sub {
			my ($s,$con) = @_;
			$con->{m}{from} or return $con->reply("503 Error: need MAIL command");
			$con->{m}{to}   or return $con->reply("554 Error: need RCPT command");
			$con->reply("354 End data with <CR><LF>.<CR><LF>");
			$con->data(cb => sub {
				$con->{m}{data} = shift;
				$s->event( mail => delete $con->{m} );
				$con->ok("I'll take it");
			});
		},
		QUIT => sub {
			my ($s,$con,$to,@args) = @_;
			$con->reply("221 Bye.");
			$con->close;
			return;
		},
		HELP => sub { $_[1]->reply("214 Ho help available.") },
		NOOP => sub { $_[1]->reply("252 Ok.") },
		EXPN => sub { $_[1]->reply("252 Nice try.") },
		VRFY => sub { $_[1]->reply("252 Nice try.") },
	);
	$self;
}

sub stop {
	my $self = shift;
	for (keys %{ $self->{c} }) {
		$self->{c}{$_} and $self->{c}{$_}->close;
	}
	delete $self->{c};
	delete $self->{s};
	return;
}

sub start {
	my $self = shift;
	$self->eventcan('command') or croak "Server implementation $self doesn't parses commands";
	#$self->{engine} or croak "Server implementation $self doesn't have engine";
	$self->{s} = tcp_server $self->{host}, $self->{port}, sub {
		my ($fh,$host,$port) = @_;
		unless ($fh) {
			$self->event( error => "couldn't accept client: $!" );
			return;
		}
		$self->accept_connection(@_);
	};
	warn "Server started on port $self->{port}\n" if $self->{debug};
}

sub accept_connection {
	my ($self,$fh,$host,$port) = @_;
	#print "Client connected $host:$port\n";
	my $con = AnyEvent::SMTP::Conn->new(
		fh => $fh,
		host => $host,
		port => $port,
		debug => $self->{debug},
	);
	$self->{c}{int $con} = $con;
	$con->reg_cb(
		disconnect => sub {
			delete $self->{c}{int $_[0]};
			$self->event( disconnect => $_[0], $_[1] );
		},
		command => sub {
			$self->event( command => @_ )
		},
	);
	$self->eventif( client => $con );
	$con->reply("220 $self->{hostname} AnyEvent::SMTP Ready.");
	$con->want_command;
}

sub eventif {
	#my ($self,$name) = @_;
	my $self = shift;my $name = shift;
	return 0 unless $self->eventcan($name);
	$self->event($name => @_);
	return 1;
	#goto &{ $self->can('event') };
}

sub eventcan {
	my $self = shift;
	my $name = shift;
	return undef unless exists $self->{__oe_events}{$name};
	return scalar @{ $self->{__oe_events}{$name} };
}

sub handle {
	my ($self,$con, $cmd, @args ) = @_;
	$self->eventif( $cmd => $con, @args )
		or do {
			$con->reply("500 Not Supported");
			warn "$cmd event not handled ($cmd @args)";
			0;
		};
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
