
package POE::Component::MessageQueue::Storage::Complex;
use base qw(POE::Component::MessageQueue::Storage);

use POE;
use POE::Component::MessageQueue::Storage::DBI;
use POE::Component::MessageQueue::Storage::Memory;
use DBI;
use strict;

use Data::Dumper;

my $DB_CREATE = << "EOF";
CREATE TABLE messages
(
	message_id  int primary key,
	destination varchar(255) not null,
	persistent  char(1) default 'Y' not null,
	in_use_by   int,
	body        text
);

CREATE INDEX destination_index ON messages ( destination );
CREATE INDEX in_use_by_index   ON messages ( in_use_by );
EOF

sub new
{
	my $class = shift;
	my $args  = shift;

	my $data_dir;
	my $timeout;

	if ( ref($args) eq 'HASH' )
	{
		$data_dir = $args->{data_dir};
		$timeout  = $args->{timeout} || 6;
	}

	# create the datadir
	if ( not -d $data_dir )
	{
		mkdir $data_dir || die "Couldn't make data dir '$data_dir': $!";
	}

	my $db_file     = "$data_dir/mq.db";
	my $db_dsn      = "DBI:SQLite2:dbname=$db_file";
	my $db_username = "";
	my $db_password = "";

	# setup sqlite for backstore
	if ( not -f $db_file )
	{
		# create initial database
		my $dbh = DBI->connect($db_dsn, $db_username, $db_password);
		$dbh->do( $DB_CREATE );
		$dbh->disconnect();
	}

	# our memory-based front store
	my $front_store = POE::Component::MessageQueue::Storage::Memory->new();

	# setup the DBI backing store
	my $back_store = POE::Component::MessageQueue::Storage::DBI->new({
		dsn       => $db_dsn,
		username  => $db_username,
		password  => $db_password,
		data_dir  => $data_dir,
		use_files => 1
	});

	# the delay is half of the given timeout
	my $delay = int($timeout / 2);

	my $self = $class->SUPER::new( $args );

	$self->{front_store} = $front_store;
	$self->{back_store}  = $back_store;
	$self->{data_dir}    = $data_dir;
	$self->{timeout}     = $timeout;
	$self->{delay}       = $delay;
	$self->{timestamps}  = { };

	# our session that does the timed message check-up.
	my $session = POE::Session->create(
		inline_states => {
			_start => sub {
				$_[KERNEL]->yield('_check_messages');
			},
		},
		object_states => [
			$self => [
				'_check_messages',
			]
		]
	);
	$self->{session} = $session;

	return $self;
}

sub set_message_stored_handler
{
	my ($self, $handler) = @_;

	$self->SUPER::set_message_stored_handler( $handler );

	$self->{front_store}->set_message_stored_handler( $handler );
	$self->{back_store}->set_message_stored_handler( $handler );
}

sub set_dispatch_message_handler
{
	my ($self, $handler) = @_;
	
	$self->SUPER::set_dispatch_message_handler( $handler );

	$self->{front_store}->set_dispatch_message_handler( $handler );
	$self->{back_store}->set_dispatch_message_handler( $handler );
}

sub set_destination_ready_handler
{
	my ($self, $handler) = @_;

	$self->SUPER::set_destination_ready_handler( $handler );

	$self->{front_store}->set_destination_ready_handler( $handler );
	$self->{back_store}->set_destination_ready_handler( $handler );
}

sub set_logger
{
	my ($self, $logger) = @_;

	$self->SUPER::set_logger( $logger );

	$self->{front_store}->set_logger( $logger );
	$self->{back_store}->set_logger( $logger );
}

sub get_next_message_id
{
	my $self = shift;
	return $self->{back_store}->get_next_message_id();
}

sub store
{
	my ($self, $message) = @_;

	$self->{front_store}->store( $message );

	# mark the timestamp that this message was added
	$self->{timestamps}->{$message->{message_id}} = time();

	$self->_log( "STORE: MEMORY: Added $message->{message_id} to in-memory store" );
}

sub remove
{
	my ($self, $message_id) = @_;

	if ( $self->{front_store}->remove( $message_id ) )
	{
		$self->_log( "STORE: MEMORY: Removed $message_id from in-memory store" );
	}
	else
	{
		$self->{back_store}->remove( $message_id );
	}

	# remove the timestamp
	delete $self->{timestamps}->{$message_id};
}

sub claim_and_retrieve
{
	my $self = shift;

	# first, try the front store.
	if ( $self->{front_store}->claim_and_retrieve(@_) )
	{
		# A message was claimed!  We're cool.
		return 1;
	}
	else
	{
		# then try the back store.
		return $self->{back_store}->claim_and_retrieve(@_);
	}
}

# unmark all messages owned by this client
sub disown
{
	my ($self, $client_id) = @_;

	$self->{front_store}->disown( $client_id );
	$self->{back_store}->disown( $client_id );
}

# our periodic check to move messages into the backing store
sub _check_messages
{
	my ($self, $kernel) = @_[ OBJECT, KERNEL ];

	$self->_log( 'debug', 'STORE: COMPLEX: Checking for outdated messages' );

	my $threshold = time() - $self->{timeout};
	my @outdated;

	# get a list of message_ids that should be moved
	while( my ($message_id, $timestamp) = each %{$self->{timestamps}} )
	{
		if ( $threshold >= $timestamp )
		{
			push @outdated, $message_id;
		}
	}

	# remove the outdated messages from the front store and send them to the back store
	if ( scalar @outdated > 0)
	{
		my $messages = $self->{front_store}->remove_unused( \@outdated );
		foreach my $message ( @$messages )
		{
			$self->_log( "STORE: COMPLEX: Moving message $message->{message_id} into backing store" );

			# do it, to it!
			$self->{back_store}->store( $message );

			# get off the timestamp list so they aren't considered again
			delete $self->{timestamps}->{$message->{message_id}};
		}
	}

	# keep us alive
	$kernel->delay( '_check_messages', $self->{delay} );
}

1;

