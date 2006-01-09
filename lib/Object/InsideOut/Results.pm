package Object::InsideOut::Results; {

use strict;
use warnings;

our $VERSION = 1.29;

use Object::InsideOut;

my @VALUES  :Field;
my @CLASSES :Field;
my @HASHES  :Field;

my %init_args :InitArgs = (
    'VALUES'  => { 'FIELD' => \@VALUES  },
    'CLASSES' => { 'FIELD' => \@CLASSES }
);

sub as_string :Stringify
{
    return (join('', grep { defined $_ } @{$VALUES[${$_[0]}]}));
}

sub count :Numerify
{
    return (scalar(@{$VALUES[${$_[0]}]}));
}

sub have_any :Boolify
{
    return (@{$VALUES[${$_[0]}]} > 0);
}

sub values :Arrayify
{
    return ($VALUES[${$_[0]}]);
}

sub as_hash :Hashify
{
    my $self = $_[0];

    if (! exists($HASHES[$$self])) {
        my %hash;
        @hash{@{$CLASSES[$$self]}} = @{$VALUES[$$self]};
        $self->set(\@HASHES, \%hash);
    }

    return ($HASHES[$$self]);
}

}  # End of package's lexical scope

1;

__END__

