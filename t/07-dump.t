use strict;
use warnings;

use Test::More 'no_plan';

package MyBase; {
    use Object::InsideOut;

    my %public  :Field;
    my %private :Field;

    my %init_args :InitArgs = (
        'pub' => {
            'field' => \%public,
        },
        'priv' => {
            'field' => \%private,
            'def'   => 'base priv',
        },
    );

    # No :Init sub needed
}

package MyDer; {
    use Object::InsideOut qw(MyBase);

    my %public  :Field;
    my %private :Field;

    my %init_args :InitArgs = (
        'pub' => {
            'field' => \%public,
        },
        'priv' => {
            'field' => \%private,
            'def'   => 'der priv',
        },
    );

    # No :Init sub needed
}

package main;

MAIN:
{
    my $obj = MyDer->new({
                  MyBase => { pub => 'base pub' },
                  MyDer  => { pub => 'der pub'  },
              });

    my $hash = $obj->_DUMP();

    ok($hash                                  => 'Representation is valid');
    is(ref($hash), 'HASH'                     => 'Representation is valid');

    is($hash->{MyBase}{'pub'}, 'base pub'     => 'Public base attribute');
    is($hash->{MyBase}{'priv'}, 'base priv'   => 'Private base attribute');

    is($hash->{MyDer}{'pub'}, 'der pub'       => 'Public derived attribute');
    is($hash->{MyDer}{'priv'}, 'der priv'     => 'Private derived attribute');

    my $str = $obj->_DUMP(1);
    my $hash2 = eval $str;

    ok($str && ! ref($str)                    => 'String dump');
    ok($hash2                                 => 'eval is valid');
    is(ref($hash2), 'HASH'                    => 'eval is valid');
    is_deeply($hash, $hash2                   => 'Dumps are equal');
}

exit(0);

# EOF
