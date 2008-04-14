#
# Copyright 2007, 2008 David Snopek <dsnopek@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package POE::Component::MessageQueue;
use vars qw($VERSION);
$VERSION = '0.2.0';

use POE 0.38;
use POE::Component::Server::Stomp;
use POE::Component::MessageQueue::Client;
use POE::Component::MessageQueue::Queue;
use POE::Component::MessageQueue::Topic;
use POE::Component::MessageQueue::Message;
use POE::Component::MessageQueue::IDGenerator::UUID;
use Net::Stomp;
use Event::Notify;
use Moose;

use constant SHUTDOWN_SIGNALS => ('TERM', 'HUP', 'INT');

has alias => (
	is      => 'ro',
	default => 'MQ',
);

sub master_alias { $_[0]->alias.'-master' }

has logger => (
	is      => 'ro',
	lazy    => 1,
	default => sub {
		my $self = shift;
		POE::Component::MessageQueue::Logger->new(
			logger_alias => $self->logger_alias
		);
	},
	handles => [qw(log)],
);

has notifier => (
	is => 'ro',
	default => sub { Event::Notify->new() },
	handles => [qw(notify register_event unregister_event)],
);

has idgen => (
	is => 'ro',
	default => sub { POE::Component::MessageQueue::IDGenerator::UUID->new() },
	handles => { generate_id => 'generate' },
);

has observers    => (is => 'ro');
has logger_alias => (is => 'ro');

has storage  => (
	is => 'ro', 
	required => 1,
);

has clients => (
	metaclass => 'Collection::Hash',
	isa       => 'HashRef[POE::Component::MessageQueue::Client]',
	default   => sub { {} },
	provides  => {
		'get'    => 'get_client',
		'delete' => 'remove_client',
		'set'    => 'set_client',
		'keys'   => 'all_client_ids',
	}
);

before remove_client => sub {
	my ($self, $id) = @_;
	my $client = $self->get_client($id) || return;

	$self->log(notice => "MASTER: Removing client $id");
	
	$self->storage->disown_all($id, sub {
		foreach my $s ($client->all_subscriptions)
		{
			$client->unsubscribe($s->destination);
			$s->destination->pump();
		}
		# shutdown TCP connection
		$client->shutdown();
	});
};
	
has destinations => (
	metaclass => 'Collection::Hash',
	isa       => 'HashRef[POE::Component::MessageQueue::Destination]',
	default   => sub { {} },
	provides  => {
		'get'    => 'get_destination',
		'set'    => 'set_destination',
		'values' => 'all_destinations',
	}
);

has owners => (
	metaclass => 'Collection::Hash',
	isa       => 'HashRef[POE::Component::MessageQueue::Subscription]',
	default   => sub { {} },
	provides  => {
		'get'    => 'get_owner',
		'set'    => 'set_owner',
		'delete' => 'delete_owner',
	},
);

sub BUILD
{
	my ($self, $args) = @_;

	my $observers = $self->observers;
	if ($observers) 
	{
		$_->register($self) for (@$observers);
	}

	$self->storage->set_logger($self->logger);

	POE::Component::Server::Stomp->new(
		Alias    => $self->alias,
		Address  => $args->{address},
		Hostname => $args->{hostname},
		Port     => $args->{port},
		Domain   => $args->{domain},

		HandleFrame        => sub { $self->_handle_frame(@_) },
		ClientDisconnected => sub { $self->_client_disconnected(@_) },
		ClientError        => sub { $self->_client_error(@_) },
	);

	# a custom session for non-STOMP responsive tasks
	POE::Session->create(
		object_states => [ $self => [qw(_start _shutdown)] ],
	);
}

sub _start
{
	my ($self, $kernel) = @_[OBJECT, KERNEL ];
	$kernel->alias_set($self->master_alias);

	# install signal handlers to initiate graceful shutdown.
	# We only respond to user-type signals - crash signals like 
	# SEGV and BUS should behave normally
	foreach my $signal ( SHUTDOWN_SIGNALS )
	{
		$kernel->sig($signal => '_shutdown'); 
	}
}

sub make_destination
{
	my ($self, $name) = @_;
	my @args = (name => $name, parent => $self);
	my $dest;

	if ($name =~ m{/queue/})
	{
		$dest = POE::Component::MessageQueue::Queue->new(@args);
	}
	elsif ($name =~ m{/topic/})
	{
		$dest = POE::Component::MessageQueue::Topic->new(@args);
	}

	$self->set_destination($name => $dest) if $dest;
	return $dest;
}

sub _handle_frame
{
	my $self = shift;
	my ($kernel, $heap, $frame) = @_[ KERNEL, HEAP, ARG0 ];

	my $id = $kernel->get_active_session()->ID();

	my $client = $self->get_client($id);
	unless ($client)
	{
		$client = POE::Component::MessageQueue::Client->new(id => $id);
		$self->set_client($id => $client);
	}

	$self->route_frame($client, $frame);
}

sub _client_disconnected
{
	my $self = shift;
	my ($kernel, $heap) = @_[ KERNEL, HEAP ];

	my $id = $kernel->get_active_session()->ID();
	$self->remove_client($id);
}

sub _client_error
{
	my $self = shift;
	my ($kernel, $name, $number, $message) = @_[ KERNEL, ARG0, ARG1, ARG2 ];

	unless ( $name eq 'read' and $number == 0 ) # Anything but EOF
	{
		$self->log(error => "Client error: $name $number $message" );
	}
}

sub _shutdown_complete
{
	my ($self) = @_;

	$self->log('alert', 'Storage engine has finished shutting down');

	# Really, really take us down!
	$self->log('alert', 'Sending TERM signal to master sessions');
	$poe_kernel->signal( $self->alias, 'TERM' );
	$poe_kernel->signal( $self->master_alias, 'TERM' );

	$self->log(alert => 'Shutting down all observers');
	if (my $oref = $self->observers)
	{
		$_->shutdown() foreach (@$oref);
	}

	$self->log(alert => 'Shutting down the logger');
	$self->logger->shutdown();
}

sub route_frame
{
	my ($self, $client, $frame) = @_;
	my $cid = $client->id;
	my $destination_name = $frame->headers->{destination};

	my %handlers = (
		CONNECT => sub {
			my $login    = $frame->headers->{login}    || q();
			my $passcode = $frame->headers->{passcode} || q();

			$self->log('notice', "RECV ($cid): CONNECT $login:$passcode");
			$client->connect($login, $passcode);
		},

		DISCONNECT => sub {
			$self->log( 'notice', "RECV ($cid): DISCONNECT");
			$self->remove_client($cid);
		},

		SEND => sub {
			my $persistent  = $frame->headers->{persistent} eq 'true' ? 1 : 0;

			$self->log(notice =>
				sprintf ("RECV (%s): SEND message (%i bytes) to %s (persistent: %i)",
					$cid, length $frame->body, $destination_name, $persistent));

			my $message = POE::Component::MessageQueue::Message->new(
				id          => $self->generate_id(),
				destination => $destination_name,
				persistent  => $persistent,
				body        => $frame->body,
			);

			unless ($persistent)
			{
				my $after = $frame->headers->{'expire-after'};
				$message->expire_at(time() + $after) if $after;
			}

			if(my $d = $self->get_destination ($destination_name) ||
			           $self->make_destination($destination_name))
			{
				$self->notify( 'recv', {
					destination => $d,
					message     => $message,
					client      => $client,
				});
				$d->send($message);
			}
			else
			{
				$self->log(error => "Don't know how to send to $destination_name");
			}
		},

		SUBSCRIBE => sub {
			my $ack_type = $frame->headers->{ack} || 'auto';

			$self->log('notice',
				"RECV ($cid): SUBSCRIBE $destination_name (ack: $ack_type)");

			if(my $d = $self->get_destination ($destination_name) ||
			           $self->make_destination($destination_name))
			{
				$client->subscribe($d, $ack_type);
				$self->notify(subscribe => {destination => $d, client => $client});
				$d->pump();
			}
			else
			{
				$self->log(error => "Don't know how to subscribe to $destination_name");
			}
		},

		UNSUBSCRIBE => sub {
			$self->log('notice', "RECV ($cid): UNSUBSCRIBE $destination_name");
			if(my $d = $self->get_destination($destination_name))
			{
				$client->unsubscribe($d);
				$self->notify(unsubscribe => {destination => $d, client => $client});
			}
		},

		ACK => sub {
			my $message_id = $frame->headers->{'message-id'};
			$self->log('notice', "RECV ($cid): ACK - message $message_id");
			$self->ack_message($client, $message_id);
		},
	);

	if (my $fn = $handlers{$frame->command})
	{
		$fn->();
		# Send receipt on anything but a connect
		if ($frame->command ne 'CONNECT' && 
				$frame->headers && 
				(my $receipt = $frame->headers->{receipt}))
		{
			$client->send_frame(Net::Stomp::Frame->new({
				command => 'RECEIPT',
				headers => {receipt => $receipt},
			}));
		}
	}
	else
	{
		$self->log('error', 
			"ERROR: Don't know how to handle frame: " . $frame->as_string);
	}
}

sub ack_message
{
	my ($self, $client, $message_id) = @_;
	my $client_id = $client->id;

	my $s = $self->get_owner($message_id);
	if ($s && $s->client->id eq $client_id)
	{
		$self->delete_owner($message_id);
		$s->ready(1);
		my $d = $s->destination;
		$self->notify(ack => {
			destination  => $d,
			client       => $client,
			message_info => {
				message_id => $message_id,
			},
		});
		$self->storage->remove($message_id, sub {$d->pump()});
	}
	else
	{
		$self->log(alert => "DANGER: Client $client_id trying to ACK message ".
			"$message_id, which he does not own!");
		return;
	}
}

sub _shutdown 
{
	my ($self, $kernel, $signal) = @_[ OBJECT, KERNEL, ARG0 ];
	$self->log('alert', "Got SIG$signal. Shutting down.");
	$kernel->sig_handled();
	$self->shutdown(); 
}

sub shutdown
{
	my $self = shift;

	if ( $self->{shutdown} )
	{
		$self->{shutdown}++;
		if ( $self->{shutdown} >= 3 )
		{
			# If we handle three shutdown signals, we'll just die.  This is handy
			# during debugging, and no one who wants MQ to shutdown gracefully will
			# throw 3 kills at us.  TODO:  Make sure that's true.
			my $msg = 
				"Shutdown called $self->{shutdown} times!  Forcing ungraceful quit.";
			$self->log('emergency', $msg);
			print STDERR "$msg\n";
			$poe_kernel->stop();
		}
		return;
	}
	$self->{shutdown} = 1;

	$self->log('alert', 'Initiating message queue shutdown...');

	$self->log(alert => 'Shutting down all destinations');
	$_->shutdown() foreach $self->all_destinations;

	# stop listening for connections
	$poe_kernel->post( $self->alias => 'shutdown' );

	# shutdown all client connections
	$poe_kernel->post($_ => 'shutdown') foreach ($self->all_client_ids);

	# shutdown the storage
	$self->storage->storage_shutdown(sub { $self->_shutdown_complete(@_) });
}

sub dispatch_message
{
	my ($self, $msg, $subscriber) = @_;
	my $msg_id = $msg->id;
	my $destination = $self->get_destination($msg->destination);

	if(my $client = $subscriber->client)
	{
		my $client_id = $client->id;
		if ($client->send_frame($msg->create_stomp_frame()))
		{
			$self->log(info => "Dispatching message $msg_id to client $client_id");
			if ($subscriber->ack_type eq 'client')
			{
				$subscriber->ready(0);
				$self->set_owner($msg_id => $subscriber);
			}
			else
			{
				$self->storage->remove($msg_id);
			}
			$self->notify(dispatch => {
				destination => $destination, 
				message     => $msg, 
				client      => $client,
			});
		}
		else
		{
			$self->log(warning => 
				"MASTER: Couldn't send frame to client $client_id: removing.");
			$self->remove_client($client_id);
		}
	}
	else
	{
		$self->log(warning => 
			"MASTER: Message $msg_id could not be delivered (no client)");
		if ($msg->claimed)
		{
			$self->storage->disown_all($msg->claimant, sub {
				$destination->pump();
			});
		}
	}
}

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue - A POE message queue that uses STOMP for the communication protocol

=head1 SYNOPSIS

  use POE;
  use POE::Component::Logger;
  use POE::Component::MessageQueue;
  use POE::Component::MessageQueue::Storage::Default;
  use strict;

  my $DATA_DIR = '/tmp/perl_mq';

  # we create a logger, because a production message queue would
  # really need one.
  POE::Component::Logger->spawn(
    ConfigFile => 'log.conf',
    Alias      => 'mq_logger'
  );

  POE::Component::MessageQueue->new({
    port     => 61613,            # Optional.
    address  => '127.0.0.1',      # Optional.
    hostname => 'localhost',      # Optional.
    domain   => AF_INET,          # Optional.
    
    logger_alias => 'mq_logger',  # Optional.

    # Required!!
    storage => POE::Component::MessageQueue::Storage::Default->new({
      data_dir     => $DATA_DIR,
      timeout      => 2,
      throttle_max => 2
    })
  });

  POE::Kernel->run();
  exit;

=head1 COMMAND LINE

If you are only interested in running with the recommended storage backend and
some predetermined defaults, you can use the included command line script.

  POE::Component::MessageQueue version 0.1.8
  Copyright 2007, 2008 David Snopek (http://www.hackyourlife.org)
  Copyright 2007, 2008 Paul Driver <frodwith@gmail.com>
  Copyright 2007 Daisuke Maki <daisuke@endeworks.jp>
  
  mq.pl [--port|-p <num>] [--hostname|-h <host>]
        [--front-store <str>] [--nouuids]
        [--timeout|-i <seconds>]   [--throttle|-T <count>]
        [--data-dir <path_to_dir>] [--log-conf <path_to_file>]
        [--stats] [--stats-interval|-i <seconds>]
        [--background|-b] [--pidfile|-p <path_to_file>]
        [--crash-cmd <path_to_script>]
        [--debug-shell] [--version|-v] [--help|-h]
  
  SERVER OPTIONS:
    --port     -p <num>     The port number to listen on (Default: 61613)
    --hostname -h <host>    The hostname of the interface to listen on 
                            (Default: localhost)
  
  STORAGE OPTIONS:
    --front-store -f <str>  Specify which in-memory storage engine to use for
                            the front-store (can be memory or bigmemory).
    --timeout  -i <secs>    The number of seconds to keep messages in the 
                            front-store (Default: 4)
    --[no]uuids             Use (or do not use) UUIDs instead of incrementing
                            integers for message IDs.  Default: uuids 
    --throttle -T <count>   The number of messages that can be stored at once 
                            before throttling (Default: 2)
    --data-dir <path>       The path to the directory to store data 
                            (Default: /var/lib/perl_mq)
    --log-conf <path>       The path to the log configuration file 
                            (Default: /etc/perl_mq/log.conf
  
  STATISTICS OPTIONS:
    --stats                 If specified the, statistics information will be 
                            written to $DATA_DIR/stats.yml
    --stats-interval <secs> Specifies the number of seconds to wait before 
                            dumping statistics (Default: 10)
  
  DAEMON OPTIONS:
    --background -b         If specified the script will daemonize and run in the
                            background
    --pidfile    -p <path>  The path to a file to store the PID of the process
  
    --crash-cmd  <path>     The path to a script to call when crashing.
                            A stacktrace will be printed to the script's STDIN.
                            (ex. 'mail root@localhost')
  
  OTHER OPTIONS:
    --debug-shell           Run with POE::Component::DebugShell
    --version    -v         Show the current version.
    --help       -h         Show this usage message

=head1 DESCRIPTION

This module implements a message queue [1] on top of L<POE> that communicates
via the STOMP protocol [2].

There exist a few good Open Source message queues, most notably ActiveMQ [3] which
is written in Java.  It provides more features and flexibility than this one (while
still implementing the STOMP protocol), however, it was (at the time I last used it)
very unstable.  With every version there was a different mix of memory leaks, persistence
problems, STOMP bugs, and file descriptor leaks.  Due to its complexity I was
unable to be very helpful in fixing any of these problems, so I wrote this module!

This component distinguishes itself in a number of ways:

=over 4

=item *

No OS threads, its asynchronous.  (Thanks to L<POE>!)

=item *

Persistence was a high priority.

=item *

A strong effort is put to low memory and high performance.

=item *

Message storage can be provided by a number of different backends.

=back

=head1 STORAGE

When creating an instance of this component you must pass in a storage object
so that the message queue knows how to store its messages.  There are some storage
backends provided with this distribution.  See their individual documentation for 
usage information.  Here is a quick break down:

=over 4

=item *

L<POE::Component::MessageQueue::Storage::Memory> -- The simplest storage engine.  It keeps messages in memory and provides absolutely no presistence.

=item *

L<POE::Component::MessageQueue::Storage::DBI> -- Uses Perl L<DBI> to store messages.  Depending on your database configuration, using directly may not be recommended because the message bodies are stored directly in the database.  Wrapping with L<POE::Component::MessageQueue::Storage::FileSystem> allows you to store the message bodies on disk.  All messages are stored persistently.  (Underneath this is really just L<POE::Component::MessageQueue::Storage::Generic> and L<POE::Component::MessageQueue::Storage::Generic::DBI>)

=item *

L<POE::Component::MessageQueue::Storage::FileSystem> -- Wraps around another storage engine to store the message bodies on the filesystem.  This can be used in conjunction with the DBI storage engine so that message properties are stored in DBI, but the message bodies are stored on disk.  All messages are stored persistently regardless of whether a message has the persistent flag set or not.

=item *

L<POE::Component::MessageQueue::Storage::Generic> -- Uses L<POE::Component::Generic> to wrap storage modules that aren't asynchronous.  Using this module is the easiest way to write custom storage engines.

=item *

L<POE::Component::MessageQueue::Storage::Generic::DBI> -- A synchronous L<DBI>-based storage engine that can be used in side of Generic.  This provides the basis for the L<POE::Component::MessageQueue::Storage::DBI> module.

=item *

L<POE::Component::MessageQueue::Storage::Throttled> -- Wraps around another engine to limit the number of messages sent to be stored at once.  Use of this module is B<highly> recommend!  If the storage engine is unable to store the messages fast enough (ie. with slow disk IO) it can get really backed up and stall messages coming out of the queue, allowing execessive producers to basically monopolise the server, preventing any messages from getting distributed to subscribers.  Also, it will significantly cuts down the number of open FDs when used with L<POE::Component::MessageQueue::Storage::FileSystem>.

=item *

L<POE::Component::MessageQueue::Storage::Complex> -- A configurable storage engine that keeps a front-store (something fast) and a back-store (something persistent), allowing you to specify a timeout and an action to be taken when messages in the front-store expire, by default, moving them into the back-store.  It is capable of correctly handling a messages persistent flag.  This optimization allows for the possibility of messages being handled before ever having to be persisted.

=item *

L<POE::Component::MessageQueue::Storage::Default> -- A combination of the Complex, Memory, FileSystem, DBI and Throttled modules above.  It will keep messages in Memory and move them into FileSystem after a given number of seconds, throttling messages passed into DBI.  The DBI backend is configured to use SQLite.  It is capable of correctly handling a messages persistent flag.  This is the recommended storage engine and should provide the best performance in the most common case (ie. when both providers and consumers are connected to the queue at the same time).

=back

=head1 CONSTRUCTOR PARAMETERS

=over 2

=item storage => SCALAR

The only required parameter.  Sets the object that the message queue should use for
message storage.  This must be an object that follows the interface of
L<POE::Component::MessageQueue::Storage> but doesn't necessarily need to be a child
of that class.

=item alias => SCALAR

The session alias to use.

=item port => SCALAR

The optional port to listen on.  If none is given, we use 61613 by default.

=item address => SCALAR

The option interface address to bind to.  It defaults to INADDR_ANY or INADDR6_ANY
when using IPv4 or IPv6, respectively.

=item hostname => SCALAR

The optional name of the interface to bind to.  This will be converted to the IP and
used as if you set I<address> instead.  If you set both I<hostname> and I<address>,
I<address> will override this value.

=item domain => SCALAR

Optionally specifies the domain within which communication will take place.  Defaults
to AF_INET.

=item logger_alias => SCALAR

Opitionally set the alias of the POE::Component::Logger object that you want the message
queue to log to.  If no value is given, log information is simply printed to STDERR.

=item observers => ARRAYREF

Optionally pass in a number of objects that will receive information about events inside
of the message queue.

Currently, only one observer is provided with the PoCo::MQ distribution:
L<POE::Component::MessageQueue::Statistics>.  Please see its documentation for more information.

=back

=head1 REFERENCES

=over 4

=item [1]

L<http://en.wikipedia.org/Message_Queue> -- General information about message queues

=item [2]

L<http://stomp.codehaus.org/Protocol> -- The informal "spec" for the STOMP protocol

=item [3]

L<http://www.activemq.org/> -- ActiveMQ is a popular Java-based message queue

=back

=head1 UPGRADING FROM OLDER VERSIONS

If you used any of the following storage engines with PoCo::MQ 0.1.7 or older:

=over 4

=item *

L<POE::Component::MessageQueue::Storage::DBI>

=back

The database format has changed.

B<Note:> When using L<POE::Component::MessageQueue::Storage::Default> (meaning mq.pl)
the database will be automatically updated in place, so you don't need to worry
about this.

Included in the distribution, is a schema/ directory with a few SQL scripts for 
upgrading:

=over

=item *

upgrade-0.1.7.sql -- Apply if you are upgrading from version 0.1.6 or older.

=item *

ugrade-0.1.8.sql -- Apply if your are upgrading from version 0.1.7 or after applying
the above update script.

=back

=head1 CONTACT

Please check out the Google Group at:

L<http://groups.google.com/group/pocomq>

Or just send an e-mail to: pocomq@googlegroups.com

=head1 DEVELOPMENT

If you find any bugs, have feature requests, or wish to contribute, please
contact us at our Google Group mentioned above.  We'll do our best to help you
out!

Development is coordinated via Bazaar (See L<http://bazaar-vcs.org>).  The main
Bazaar branch can be found here:

L<http://code.hackyourlife.org/bzr/dsnopek/perl_mq>

We prefer that contributions come in the form of a published Bazaar branch with the
changes.  This helps facilitate the back-and-forth in the review process to get
any new code merged into the main branch.

=head1 FUTURE

The goal of this module is not to support every possible feature but rather to be
small, simple, efficient and robust.  So, for the most part expect only incremental
changes to address those areas.  Other than that, here are some things I would like
to implement someday in the future:

=over 4

=item *

Full support for the STOMP protocol.

=item *

Some kind of security based on username/password.

=item *

Optional add on module via L<POE::Component::IKC::Server> that allows to introspect the state of the message queue.

=back

=head1 SEE ALSO

I<External modules:>

L<POE>, L<POE::Component::Server::Stomp>, L<Net::Stomp>, L<POE::Component::Logger>, L<DBD::SQLite>,
L<POE::Component::Generic>, L<POE::Filter::Stomp>

I<Storage modules:>

L<POE::Component::MessageQueue::Storage>,
L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::BigMemory>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::Generic>,
L<POE::Component::MessageQueue::Storage::Generic::DBI>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>,
L<POE::Component::MessageQueue::Storage::Default>

I<Statistics modules:>

L<POE::Component::MessageQueue::Statistics>,
L<POE::Component::MessageQueue::Statistics::Publish>,
L<POE::Component::MessageQueue::Statistics::Publish::YAML>

=head1 BUGS

We are serious about squashing bugs!  Currently, there are no known bugs, but
some probably do exist.  If you find any, please let us know at the Google group.

That said, we are using this in production in a commercial application for
thousands of large messages daily and we experience very few issues.

=head1 AUTHORS

Copyright 2007, 2008 David Snopek (L<http://www.hackyourlife.org>)

Copyright 2007, 2008 Paul Driver <frodwith@gmail.com>

Copyright 2007 Daisuke Maki <daisuke@endeworks.jp>

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

