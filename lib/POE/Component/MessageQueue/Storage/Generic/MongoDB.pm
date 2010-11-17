#
# Copyright 2007-2010 David Snopek <dsnopek@gmail.com>
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

package POE::Component::MessageQueue::Storage::Generic::MongoDB;
use Moose;

with qw(POE::Component::MessageQueue::Storage::Generic::Base);

use MongoDB;
use Exception::Class::DBI;
use Exception::Class::TryCatch;
use 5.010;

sub dsn      { return $_[0]->servers->[0]->{dsn}; }
sub options  { return $_[0]->servers->[0]->{options}; }

has 'servers' => (
	is => 'ro',
	isa => 'ArrayRef[HashRef]',
	required => 1,
	default => sub { return [] },
);

has 'mq_id' => (
	is       => 'ro',
	isa      => 'Str',
);

# will reference the collection we're going to put our messages in
has 'db' => (
	is       => 'ro',
    lazy => 1,
    default => sub { $_[0]->dbh->mq->msgs },
);

has 'dbh' => (
	is => 'ro',
	isa => 'Object',
	writer => '_dbh',
	lazy => 1,
	builder => '_connect',
	init_arg => undef,
);

has 'cur_server' => (
	is => 'ro',
	isa => 'Int',
	writer => '_cur_server',
	default => sub { return -1 },
	init_arg => undef,
);

sub _clear_claims {
	my ($self) = @_;
    my $mq_id = $self->mq_id;
	if (defined $mq_id and $mq_id ne '') {
        $self->db->update({in_use_by => qr/^$mq_id:.*/}, {'$set' => {in_use_by => undef}}, {multiple => 1});
    }
}

around BUILDARGS => sub
{
	my ($orig, $class) = @_;
	my %args = @_;

	if (!defined($args{servers})) {
		$args{servers} = [{
			dsn      => $args{dsn},
			options  => $args{options} || {},
		}];
	}

	return $class->$orig(%args);
};

sub BUILD 
{
	my ($self, $args) = @_;

	foreach my $server (@{$self->servers}) {
		if (!defined $server->{options}) {
			$server->{options} = {};
		}
	}

	# This actually makes DBH connect
	$self->_clear_claims();
}

sub _connect
{
	my ($self) = @_;

    my $dsn = $self->servers->[0]->{dsn};
    my %options;
    if ($dsn) {
        my $regex = qr{^mongodb://
                        (?: (?<username>\w+) : (?<password>[^@]+) @)?
                        (?<hosts> (?:[^/@]+(?::\d+)?))+
                        (?:/ (?<db> .+))?
                    }x;
        if ($dsn !~ $regex) {
            $self->log(error => "to make sense of the dsn string: '$dsn'");
            exit 1;
        }
        $options{host} = "mongodb://$+{hosts}";
    } 

    $options{password} = $+{password} if $+{password};
    $options{username} = $+{username} if $+{username};

    my $dbh = MongoDB::Connection->new(%options);

	$self->log(alert => 'connected to MongoDB');

    $dbh->mq->msgs->ensure_index({timestamp   => 1});
    $dbh->mq->msgs->ensure_index({destination => 1});
    $dbh->mq->msgs->ensure_index({in_use_by   => 1});
    $dbh->mq->msgs->ensure_index({deliver_at  => 1});

    $dbh
}

sub _in_use_by {
	my ($self, $client_id) = @_;
	if (defined $client_id and defined $self->mq_id and $self->mq_id ne '') {
		return $self->mq_id .":". $client_id;
	}
	return $client_id;
}

# Note:  We explicitly set @_ in all the storage methods in this module,
# because when we do our tail-calls (goto $method), we don't want to pass them
# anything unneccessary, particulary $callbacks.

sub store
{
	my ($self, $m, $callback) = @_;

    # mongodb can only use '$gt', '$lt', etc, operators on integers, and this is
    # how we coax perl into storing these fields as integers so we can query on
    # them as such.
    $m->{deliver_at} = 0+$m->{deliver_at}; # convert this to an int.

    $m->{_id} = $m->{id}; delete $m->{id};

    # TODO: we should put the body into mongo's GridFS
    $self->db->insert($m);
	@_ = ();
	goto $callback if $callback;
}

sub _make_message { 
	my ($self, $h) = @_;
	my %map = (
		id          => '_id',
		destination => 'destination',
		body        => 'body',
		persistent  => 'persistent',
		claimant    => 'in_use_by',
		size        => 'size',
		timestamp   => 'timestamp',
		deliver_at  => 'deliver_at',
	);
	my %args;
	foreach my $field (keys %map) 
	{
		my $val = $h->{$map{$field}};
		$args{$field} = $val if (defined $val);
	}
	# pull only the client ID out of the in_use_by field
	my $mq_id = $self->mq_id;
	if (defined $mq_id and $mq_id ne '' and defined $args{claimant}) {
		$args{claimant} =~ s/^$mq_id://;
	}
	return POE::Component::MessageQueue::Message->new(%args);
};

sub get
{
	my ($self, $message_ids, $callback) = @_;
    my @messages = map $self->_make_message($_), $self->db->find({_id => {'$in' => $message_ids}})->all;
    @_ = (\@messages);
    goto $callback;
}

sub get_all
{
	my ($self, $callback) = @_;
    @_ = ([ $self->db->find()->all ]);
    goto $callback;
}

sub get_oldest
{
	my ($self, $callback) = @_;
    @_ = ([ $self->db->find()->sort({timestamp => 1})->limit(1)->all ]);
    goto $callback;
}

sub claim_and_retrieve
{
	my ($self, $destination, $client_id, $callback) = @_;

    my @messages = map $self->_make_message($_), $self->db->find(
        {
            destination => $destination,
            in_use_by => undef,
            '$or' =>
            [
                {deliver_at => undef},
                {deliver_at => {'$lt', time()}}
            ]
        }
    )->sort({timestamp => 1})->limit(1)->all;
    @_ = @messages;

    if (my $msg = $_[0]) {
        $self->claim([$msg->{id}], $client_id);
    }
    goto $callback;
}

sub remove
{
	my ($self, $message_ids, $callback) = @_;
    $self->db->remove({_id => {'$in' => $message_ids}});
	@_ = ();
	goto $callback if $callback;
}

sub empty
{
	my ($self, $callback) = @_;
    $self->db->drop;
	@_ = ();
	goto $callback if $callback;
}

sub claim
{
	my ($self, $message_ids, $client_id, $callback) = @_;
	my $in_use_by = $self->_in_use_by($client_id);
    $self->db->update({_id => {'$in' => $message_ids}}, {'$set' => {in_use_by => $in_use_by}}, {multiple => 1});
	@_ = ();
	goto $callback if $callback;
}

sub disown_destination
{
	my ($self, $destination, $client_id, $callback) = @_;
	my $in_use_by = $self->_in_use_by($client_id);
    $self->db->update({destination => $destination, in_use_by => $in_use_by}, {'$set' => {in_use_by => undef}}, {multiple => 1});
	@_ = ();
	goto $callback if $callback;
}

sub disown_all
{
	my ($self, $client_id, $callback) = @_;
	my $in_use_by = $self->_in_use_by($client_id);
    $self->db->update({in_use_by => $in_use_by}, {'$set' => {in_use_by => undef}}, {multiple => 1});
	@_ = ();
	goto $callback if $callback;
}

sub storage_shutdown
{
	my ($self, $callback) = @_;

	$self->log(alert => 'Shutting down MongoDB storage engine...');

	$self->_clear_claims();
	$self->dbh->disconnect();
	@_ = ();
	goto $callback if $callback;
}

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue::Storage::Generic::MongoDB -- A storage engine that uses L<MongoDB>

=head1 SYNOPSIS

  use POE;
  use POE::Component::MessageQueue;
  use POE::Component::MessageQueue::Storage::Generic;
  use POE::Component::MessageQueue::Storage::Generic::MongoDB;
  use strict;

  POE::Component::MessageQueue->new({
    storage => POE::Component::MessageQueue::Storage::Generic->new({
      package => 'POE::Component::MessageQueue::Storage::MongoDB',
      options => [{
        dsn      => 'mongodb://username:password@localhost:27017',
        mq_id    => $mq_id,
      }],
    })
  });

  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

A storage engine that uses L<MongoDB>.

This module is not itself asynchronous and must be run via 
L<POE::Component::MessageQueue::Storage::Generic> as shown above.

Rather than using this module "directly" [1], I would suggest wrapping it inside of
L<POE::Component::MessageQueue::Storage::FileSystem>, to keep the message bodys on
the filesystem, or L<POE::Component::MessageQueue::Storage::Complex>, which is the
overall recommended storage engine.

If you are only going to deal with very small messages then, possibly, you could 
safely keep the message body in the database.  However, this is still not really
recommended for a couple of reasons:

=over 4

=item *

All database access is conducted through L<POE::Component::Generic> which maintains
a single forked process to do database access.  So, not only must the message body be
communicated to this other proccess via a pipe, but only one database operation can
happen at once.  The best performance can be achieved by having this forked process
do as little as possible.

=item *

A number of databases have hard limits on the amount of data that can be stored in
a BLOB (namely, SQLite, which sets an artificially lower limit than it is actually
capable of).

=item *

Keeping large amounts of BLOB data in a database is bad form anyway!  Let the database do what
it does best: index and look-up information quickly.

=back

=head1 CONSTRUCTOR PARAMETERS

=over 2

=item dsn => SCALAR

=item mq_id => SCALAR

=back

=head1 SUPPORTED STOMP HEADERS

=over 4

=item B<persistent>

I<Ignored>.  All messages are persisted.

=item B<expire-after>

I<Ignored>.  All messages are kept until handled.

=item B<deliver-after>

I<Fully Supported>.

=back

=head1 FOOTNOTES

=over 4

=item [1] 

By "directly", I still mean inside of L<POE::Component::MessageQueue::Storage::Generic> because
that is the only way to use this module.

=back

=head1 SEE ALSO

L<POE::Component::MessageQueue>,
L<POE::Component::MessageQueue::Storage>,
L<DBI>

I<Other storage engines:>

L<POE::Component::MessageQueue::Storage::Memory>,
L<POE::Component::MessageQueue::Storage::BigMemory>,
L<POE::Component::MessageQueue::Storage::DBI>,
L<POE::Component::MessageQueue::Storage::FileSystem>,
L<POE::Component::MessageQueue::Storage::Generic>,
L<POE::Component::MessageQueue::Storage::Throttled>,
L<POE::Component::MessageQueue::Storage::Complex>,
L<POE::Component::MessageQueue::Storage::Default>

=cut

