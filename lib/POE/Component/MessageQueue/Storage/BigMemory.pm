#
# Copyright 2007 Paul Driver <frodwith@gmail.com>
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

use strict;
package POE::Component::MessageQueue::Storage::BigMemory;
use base qw(POE::Component::MessageQueue::Storage);

use POE::Component::MessageQueue::Storage::Structure::DLList;

sub new
{
	my $class = shift;
	my $self  = $class->SUPER::new(@_);

	# claimed messages (removed from named queues when claimed).
	# Key: Client ID.
	# Value: A doubly linked queue of messages.
	$self->{claimed} = {};

	# Named queues.
	# Key: Queue Name
	# Value: A doubly linked queue of messages
	$self->{unclaimed} = {};   

	# All messages.
	# Key: A message id
	# Value: A cell in a doubly linked queue
	$self->{messages} = {};

	return bless $self, $class;
}

sub has_message
{
	my ($self, $id) = @_;

	return ( exists($self->{messages}->{$id}) );
}

sub _force_store {
	my ($self, $hashname, $key, $message) = @_;
	my $id = $message->{message_id}; 
	unless ( exists $self->{$hashname}->{$key} )
	{
		$self->{$hashname}->{$key} = 
			POE::Component::MessageQueue::Storage::Structure::DLList->new();
	}
	$self->{messages}->{$id} = $self->{$hashname}->{$key}->enqueue($message); 
	return;
}

sub store
{
	my ($self, $message) = @_;
	my $claimant = $message->{in_use_by};

	if ( defined $claimant )
	{
		$self->_force_store('claimed', $claimant, $message);
	}
	else
	{
		$self->_force_store('unclaimed', $message->{destination}, $message);
	}

	$self->_log('info', "STORE: BIGMEMORY: Added $message->{message_id}.");
	$self->call_back('message_stored', $message);
	return;
}

sub remove
{
	my ($self, $id, $callback) = @_;
	my $cell = delete $self->{messages}->{$id};
	unless ($cell)
	{
		$callback->(undef) if $callback;
		return;
	}
	my $message = $cell->delete();

	my $claimant = $message->{in_use_by};

	if ( $claimant )
	{
		delete $self->{claimed}->{$claimant};
	}
	else
	{
		delete $self->{unclaimed}->{$message->{destination}};
	}

	$callback->($message) if $callback;
	$self->_log('info', "STORE: BIGMEMORY: Removed $id from in-memory store");
	return;
}

sub remove_multiple
{
	my ($self, $message_ids, $callback) = @_;
	my @messages = ();

	my $pusher = $callback && sub { 
		my $m = shift;
		push(@messages, $m) if $m;
	};

	$self->remove($_, $pusher) foreach (@$message_ids);
	$callback->(\@messages) if $callback;	
	return;
}

sub remove_all 
{
	my ($self, $callback) = @_;
	if ($callback)
	{
		my @messages = map { $_->data() } (values %{$self->{messages}});
		$callback->(\@messages);	
	}
	%{$self->{$_}} = () foreach qw(messages claimed unclaimed);
	return;
}

sub claim_and_retrieve
{
	my $self = shift;
	my $args = shift;

	my $destination;
	my $client_id;

	if ( ref($args) eq 'HASH' )
	{
		$destination = $args->{destination};
		$client_id   = $args->{client_id};
	}
	else
	{
		$destination = $args;
		$client_id   = shift;
	}

	# Find an unclaimed message
	my $q = $self->{unclaimed}->{$destination} || return;
	my $message = $q->dequeue() || return;

	# Claim it
	$message->{in_use_by} = $client_id;
	$self->_force_store('claimed', $client_id, $message);
	$self->_log('info',
		"STORE: BIGMEMORY: Message $message->{message_id} ".
		"claimed by client $client_id."
	);

	# Dispatch it
	$self->call_back('dispatch_message', $message, $destination, $client_id);
	$self->call_back('destination_ready', $destination);
}

# unmark all messages owned by this client
sub disown
{
	my ($self, $destination, $client_id) = @_;
	my $q = $self->{claimed}->{$client_id} || return;

	for(my $i = $q->first(); $i; $i = $i->next())
	{
		my $message = $i->data();
		if ($message->{destination} eq $destination)
		{
			$i->delete(); # ->next() still valid though.
			$self->_force_store('unclaimed', $destination, $message);
			delete $message->{in_use_by};
		}
	}
	return;
}

# We don't persist anything, so just call our complete handler.
sub shutdown
{
	my $self = shift;
	$self->call_back('shutdown_complete');
	return;
}

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue::Storage::BigMemory -- In-memory storage engine
for large values of N 

=head1 SYNOPSIS

	use POE;
	use POE::Component::MessageQueue;
	use POE::Component::MessageQueue::Storage::BigMemory;
	use strict;

	POE::Component::MessageQueue->new({
		storage => POE::Component::MessageQueue::Storage::BigMemory->new()
	});

	POE::Kernel->run();
	exit;

=head1 DESCRIPTION

This is basically Storage::Memory, but optimized to handle large numbers of
messages.  Memory stores everything as a simple list, which can slow the MQ to
a CRAWL when the number of messsages in this store gets big.

store() is a little bit slower per message in this module, and it uses
more memory per message. Everything else should be considerably more efficient,
though, especially when the number of messages starts to climb.  Many things in 
Storage::Memory are O(n*n).  Most things in this module are O(1)!

=head1 SEE ALSO

L<POE::Component::MessageQueue>,
L<POE::Component::MessageQueue::Storage>,
L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::Generic>,
L<POE::Component::MessageQueue::Storage::Generic::DBI>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>

=cut
