use strict;
use warnings;

use Test::More 'no_plan';

package MyBase; {
    use Object::InsideOut;

    my @public  :Field;
    my @private :Field;

    my %init_args :InitArgs = (
        'pub' => {
            'field' => \@public,
        },
        'priv' => {
            'field' => \@private,
            'def'   => 'base priv',
        },
    );

    # No :Init sub needed
}

package MyDer; {
    use Object::InsideOut qw(MyBase);

    my @public  :Field;
    my @private :Field;
    my @misc :Field;

    my %init_args :InitArgs = (
        'pub' => {
            'field' => \@public,
        },
        'priv' => {
            'field' => \@private,
            'def'   => 'der priv',
        },
        'misc' => '',
    );

    sub _init :Init
    {
        my ($self, $args) = @_;

        if (exists($args->{'misc'})) {
            $misc[$$self] = $args->{'misc'};
        }
    }
}

package main;

MAIN:
{
    my $obj = MyDer->new({
                  MyBase => { pub => 'base pub' },
                  MyDer  => { pub => 'der pub'  },
                  'misc' => 'other',
              });

    my $hash = $obj->dump();

    ok($hash                                  => 'Representation is valid');
    is(ref($hash), 'HASH'                     => 'Representation is valid');

    is($hash->{MyBase}{'pub'}, 'base pub'     => 'Public base attribute');
    is($hash->{MyBase}{'priv'}, 'base priv'   => 'Private base attribute');

    is($hash->{MyDer}{'pub'}, 'der pub'       => 'Public derived attribute');
    is($hash->{MyDer}{'priv'}, 'der priv'     => 'Private derived attribute');
    is(Object::InsideOut::Util::hash_re($hash->{MyDer}, qr/^ARRAY/), 'other'
                                              => 'Hidden derived attribute');

    my $str = $obj->dump(1);
    #print(STDERR $str, "\n");

    my $hash2 = eval $str;

    ok($str && ! ref($str)                    => 'String dump');
    ok($hash2                                 => 'eval is valid');
    is(ref($hash2), 'HASH'                    => 'eval is valid');
    is_deeply($hash, $hash2                   => 'Dumps are equal');
}

exit(0);

# EOF
