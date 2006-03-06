use strict;
use warnings;

use Test::More 'no_plan';

package Foo;
{
    use Object::InsideOut;
    my @data :Field('Standard' => 'data', 'Permission' => 'private');
    my @info :Field('Accessor' => 'info', 'Permission' => 'restricted');
}

package Bar;
{
    use Object::InsideOut 'Foo';

    sub bar_data
    {
        my $self = shift;
        return ($self->get_data());
    }

    sub bar_info
    {
        my $self = shift;
        if (! @_) {
            return ($self->info());
        }
        $self->info(@_);
    }
}

package main;

my $foo = Foo->new();
my $bar = Bar->new();

eval { $foo->set_data(42); };
is($@->error, q/Can't call private method 'Foo->set_data' from class 'main'/
                                    , 'Private set method');
eval { $foo->get_data(); };
is($@->error, q/Can't call private method 'Foo->get_data' from class 'main'/
                                    , 'Private get method');
eval { $foo->info(); };
is($@->error, q/Can't call restricted method 'Foo->info' from class 'main'/
                                    , 'Restricted method');

eval { $bar->bar_data(); };
is($@->error, q/Can't call private method 'Foo->get_data' from class 'Bar'/
                                    , 'Private get method');

ok($bar->bar_info(10)               => 'Restricted set');
is($bar->bar_info(), 10             => 'Restricted get')

# EOF
