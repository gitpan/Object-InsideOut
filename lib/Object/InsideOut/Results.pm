package Object::InsideOut::Results; {

use strict;
use warnings;

our $VERSION = '1.02.00';

use Object::InsideOut;

my @VALUES  : Field;
my @CLASSES : Field;

my %init_args : InitArgs = (
    'VALUES'  => { 'FIELD' => \@VALUES  },
    'CLASSES' => { 'FIELD' => \@CLASSES }
);

sub as_string : STRINGIFY
{
    return (join('', grep { defined $_ } @{$VALUES[${$_[0]}]}));
}

sub count : NUMERIFY
{
    return (scalar(@{$VALUES[${$_[0]}]}));
}

sub have_any : BOOLIFY
{
    return (@{$VALUES[${$_[0]}]} > 0);
}

sub values : ARRAYIFY
{
    return ($VALUES[${$_[0]}]);
}

sub as_hash : HASHIFY
{
    my $id = ${$_[0]};
    my %hash;
    @hash{@{$CLASSES[$id]}} = @{$VALUES[$id]};
    return (\%hash);
}

}  # End of package's lexical scope

1;

__END__

