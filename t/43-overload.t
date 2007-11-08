#!/usr/bin/perl

use strict;
use warnings;

use threads;
use threads::shared;

use Test::More 'no_plan';

package Foo; {
    use Object::InsideOut ':SHARED';
    my @objs :Field :All(obj);
}

package Bar; {
    use Object::InsideOut;
    my @objs :Field :All(obj);
    my @value :Field :All(value) :Type(numeric);

    sub num :Numerify { $value[${$_[0]}]; }

    use overload (
        '='  => 'clone',
        '++' => sub { $value[${$_[0]}]++; shift },
    );
}

package main;
MAIN:
{
    my $obj = Foo->new();
    my $obj2 = Foo->new('obj'=>$obj);
    my $x = $obj2->obj();
    isnt($x, $obj               => 'Shared objects are not the same');
    ok($x == $obj               => 'However, they equate');

    $obj = Bar->new('value' => 42);
    ok($x != $obj               => "Different objects don't equate");
    ok($$x == $$obj             => "Even if they have the same ID");

    $obj2 = Bar->new('obj'=>$obj);
    $x = $obj2->obj();
    is($x, $obj                 => 'Non-shared objects are the same');
    ok($x == $obj               => 'And they equate');

    ++$x;
    is($x->value(), 43          => '++ worked');
    is($obj->value(), 42        => 'Copy constuctor worked');
}

exit(0);

# EOF
