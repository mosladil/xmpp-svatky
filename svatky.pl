#!/usr/bin/perl -T

use strict;
use warnings;

# Modules
use Net::Jabber;
use Switch;
use utf8;
use DBI;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# Defaults
my %jabber = (
	server     => 'xmpp-server.domain.local',
	port       => 5222,
	user       => 'svatky',
	pass       => 'Secr3t',
	resource   => 'Bot',
	status     => 'Ready to help!',
	botname    => 'Svatky',
	tls        => 1,
	connection => 'tcp',
	debug      => 0
);

my $db_file     = 'svatky.db';
my @blacklist	= '(hovno, prdel, debil)';
my @admins		= '(xxlmira@mail.com)';
my $lookups     = 0;
my $max_lookups = 10;

# Objects
my $Jabber   = Net::Jabber::Client->new();
my $Presence = Net::Jabber::Presence->new();
my $Log      = Log->new();

{
	&main();
	exit;
}

sub main {
	&connect();
	&listen();

	return 1;
}

# Connect to the Jabber server and send presence.
sub connect {
	$Log->SetLog(
		from=>$$,
		type=>"notice",
		data=>"connecting"
	);

	my $server_connect = $Jabber->Connect(
		hostname   => $jabber{'server'},
		port       => $jabber{'port'},
		tls        => $jabber{'tls'},
		register   => 0,
		connection => $jabber{'connection'}
	);

	if (not defined($server_connect)) {
		die "Cannot connect to server $jabber{'server'}\n";
	}

	my @server_auth = $Jabber->AuthSend(
		username => $jabber{'user'},
		password => $jabber{'pass'},
		resource => $jabber{'resource'}
	);

	if ($server_auth[0] ne "ok") {
		$Log->SetLog(
			from=>$$,
			type=>"error",
			data=>"$server_auth[0] - $server_auth[1]"
		);

		die "Ident/Auth with server failed: $server_auth[0] - $server_auth[1]\n";
	}

	if ($jabber{'debug'} == 0) {
		exit if fork();
	}
    
	$Log->SetLog(
		from=>$$,
		type=>"notice",
		data=>"connected."
	);

	#$Jabber->RosterGet();
	&setBotStatus("available", "chat", &findByDate('dnes'));
    
	return 1;
}

# Register callbacks and then hang around waiting for requests.
# Toggles status relative to current number of lookups.
sub listen {
	$Jabber->SetCallBacks(
		message  => \&handleMessage,
		presence => \&handlePresence
	);

	while (defined($Jabber->Process())) {
		my $current_type = $Presence->GetType();

		if (($lookups >= $max_lookups) && ($current_type ne "unavailable")) {
			&setBotStatus("unavailable", "away", "I am helping someone else right now.");
		}

		if ( ($lookups < $max_lookups) && ($current_type ne "available")) {
			&setBotStatus("available", "away", &findByDate('dnes'));
		}

		if ($jabber{'status'} ne &findByDate('dnes')) {
			&setBotStatus("available", "chat", &findByDate('dnes'));
		}
	}

	$Log->SetLog(
		from=>$$,
		type=>"notice",
		data=>"disconnecting"
	);

	$Jabber->Disconnect();
	return 1;
}

sub handleMessage {
	my $jid = shift || return;
	my $msg = shift || return;

	return if ($lookups >= $max_lookups);

	$lookups++;

	my $from   = $msg->GetFrom;
	my $to     = $msg->GetTo;
	my $thread = $msg->GetThread();
	my $data   = $msg->GetBody;

	$Log->SetLog(
		from=>$from,
		type=>"notice",
		data=>"$data"
	);

	my $reply = Net::Jabber::Message->new();

	$reply->SetMessage(
		to       => $from,
		from     => $to,
		resource => $jabber{'resource'},
		thread   => $thread,
		type     => $msg->GetType,
		subject  => $msg->GetSubject,
		body     => &svatky($data),
	);

	$Jabber->Send($reply);

	$lookups--;
	return 1;
}

sub handlePresence {
	my $jid = shift || return;
	my $msg = shift || return;

	my $type = $Presence->GetType();

	if ($type eq "subscribe"){
		$Jabber->Send($Presence->Reply(type=>'subscribed'));
	} elsif ($type eq "unsubscribe") {
		$Jabber->Send($Presence->Reply(type=>'unsubscribed'));
	}
}

sub setBotStatus {
	my $type = shift;
	my $show = shift;
	my $status = shift;

	$Presence->SetType($type);
	$Presence->SetShow($show);
	$Presence->SetStatus($status);
	$Jabber->Send($Presence);
	$jabber{'status'} = $show;

	return 1;
}

# BOT functionality
sub svatky {
	my $word = shift;
	my $lcword = lc($word);
	my $result;

	# Show help howto usage
	if (($lcword =~ /napoveda/) || ($lcword =~ /help/)) {
		$result  = "Nápověda:\n";
		$result .= "dnes - zobrazí, kdo dnes slaví svátek\n";
		$result .= "zítra - zobrazí, kdo slaví svátek zítra\n";
		$result .= "25.4. - zobrazí, kdo slaví svátek 25.4.\n";
		$result .= "Karel - zobrazí, kdy slaví svátek Karel";
	}
	# Search in SQLite by date
	elsif (($lcword =~ /\d/) || ($lcword =~ /dnes/) || ($lcword =~ /zitra/)) {
		$result = &findByDate($lcword);
		if (!$result) {
			$result = "$word nikdo svátek neslaví.";
		}
	}
	# Search in SQLite by name
	elsif (($lcword =~ /\w/)) {
		my @hugo = grep(/$lcword/, @blacklist);
		if (defined($hugo[0])) {
			$result = "$word jsi ty ;-)";
		}
		else {
			$result = &findByName($lcword);
			if (!$result) {
	    		$result = "$word svátek neslaví :-)";
			}
		}
	}

	return $result;
}

# Returns name defined by today, tomorrow or custom date from SQLite database
sub findByDate {
	my $word = shift;
	my $jmeno;
	my $typ;
	my $result;

	my $SQLite = DBI->connect("dbi:SQLite:dbname=$db_file","","");
	$SQLite->{unicode} = 1;

	#Today
	if (lc($word) =~ /dnes/) {
		my @date=localtime(time);
		my $tday = $date[3];
		my $tmonth = $date[4]+1;

		my $line = $SQLite->selectall_arrayref("select jmeno,typ from jmeniny where den=$tday and mesic=$tmonth");
		foreach my $row (@$line) {
			($jmeno,$typ) = @$row;
			if ($typ == 0) {
				$result = "Dnes slaví svátek $jmeno.";
			}
			else {
				$result = "Dnes je $jmeno.";
			}
		}
	}
	# Tomorrow
	elsif (lc($word) =~ /zitra/) {
		my @date=localtime(time+86400);
		my $tday = $date[3];
		my $tmonth = $date[4]+1;

		my $line = $SQLite->selectall_arrayref("select jmeno,typ from jmeniny where den=$tday and mesic=$tmonth");
		foreach my $row (@$line) {
			my ($jmeno,$typ) = @$row;
			if ($typ == 0) {
				$result = "Zítra slaví svátek $jmeno.";
			}
			else {
				$result = "Zítra je $jmeno.";
			}
		}
	}
	# Date format - d.m. / dd.mm.
	elsif ($word =~ /\d{1,2}\.\d{1,2}\./) {
		my $day = substr($word, 0, index($word, '.'));
		my $month = substr($word, index($word, '.')+1, length($word));

		my $line = $SQLite->selectall_arrayref("select jmeno,typ from jmeniny where den=$day and mesic=$month");
		foreach my $row (@$line) {
			($jmeno,$typ) = @$row;
			if ($typ == 0) {
				$result = "$word slaví svátek $jmeno.";
			}
			else {
				$result = "$word je $jmeno.";
			}
		}
	}

	$SQLite->disconnect;
	return $result;
}

# Returns date defined by name from SQLite database
sub findByName {
	my $word = shift;
	my $jmeno = undef;
	my $result = undef;
	my $loop = undef;

	my $SQLite = DBI->connect("dbi:SQLite:dbname=$db_file","","");
	$SQLite->{unicode} = 1;

	my $line = $SQLite->selectall_arrayref("select jmeno,den,mesic,typ from jmeniny where jmeno like '%$word%'");
	foreach my $row (@$line) {
		if ($loop++ >= 1) {
			$result .= "\n";
		}
		my ($jmeno,$den,$mesic,$typ) = @$row;
		if ($typ == 0) {
			$result .= "$jmeno slaví svátek $den.$mesic.";
		}
		else {
			$result .= "$jmeno se slaví $den.$mesic.";
		}
	}

	$SQLite->disconnect;
	return $result;
}

# This is a quick hack until I figure out
# why Net::Jabber::Log doesn't think it has
# a "new" method.
package Log;

sub new {
	my $pkg  = shift;
	return bless {},$pkg;
}

sub SetLog {
	my $self = shift;
	my $args = { @_ };

	my $timestamp = time;

	if ($jabber{'debug'} == 1) {
		warn "$jabber{'botname'}: $args->{'type'} | $timestamp |  $args->{'from'} | [ $args->{'data'} ] \n";
	}
}

return 1;
