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

package POE::Component::MessageQueue::Storage::MongoDB;
use Moose;

extends qw(POE::Component::MessageQueue::Storage::Generic);

has '+package' => ( 
	default => 'POE::Component::MessageQueue::Storage::Generic::MongoDB',
);

around new => sub {
	my ($original, $class) = (shift, shift);
	my @args;
	if (ref($_[0]) eq 'HASH') {
		@args = %{$_[0]};
	} else {
		@args = @_;
	}
	$original->($class, @args, options => \@args);
};

1;

__END__

=pod

=head1 NAME

POE::Component::MessageQueue::Storage::MongoDB -- A storage engine that uses L<MongoDB>

=head1 SYNOPSIS

  use POE;
  use POE::Component::MessageQueue;
  use POE::Component::MessageQueue::Storage::MongoDB;
  use strict;

  POE::Component::MessageQueue->new({
    storage => POE::Component::MessageQueue::Storage::MongoDB->new({
      dsn      => 'mongodb://username:password@localhost:27017',
      mq_id    => $mq_id,
    })
  });

  POE::Kernel->run();
  exit;

=head1 DESCRIPTION

A storage engine that uses L<MongoDB>.  All messages stored with this backend are
persisted.


=head1 constructor parameters

=over 2

=item dsn => scalar

=item mq_id => scalar

=back

=head1 see also

l<poe::component::messagequeue>,
l<poe::component::messagequeue::storage>,
l<dbi>

i<other storage engines:>

l<poe::component::messagequeue::storage::memory>,
l<poe::component::messagequeue::storage::bigmemory>,
l<poe::component::messagequeue::storage::filesystem>,
l<poe::component::messagequeue::storage::generic>,
l<poe::component::messagequeue::storage::generic::dbi>,
l<poe::component::messagequeue::storage::throttled>,
l<poe::component::messagequeue::storage::complex>,
l<poe::component::messagequeue::storage::default>

=cut

