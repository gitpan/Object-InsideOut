use strict;
use warnings;

use Test::More 'no_plan';

package My::Class; {
    use Object::InsideOut;

    sub jinx : Cumulative(bottom up);

    sub auto : Automethod
    {
        my $name = $_;
        return sub {
                        my $self = $_[0];
                        my $class = ref($self) || $self;
                        return "$class->$name";
                   };
    };

    sub jinx
    {
        return 'My::Class->jinx';
    }
}


package My::Sub; {
    use Object::InsideOut qw(My::Class);

    sub jinx : Cumulative(bottom up)
    {
        return 'My::Sub->jinx';
    }

    sub foo
    {
        return 'My::Sub->foo';
    }
}


package Bar; {
    use Object::InsideOut qw(My::Class);

    sub AUTOMETHOD {
        if (/^foo$/) {
            return sub { return 'Bar->foo' }
        }
        return;
    }
}


package Baz; {
    use Object::InsideOut qw(Bar);
}


package My::MT; {
    sub new { return bless({}, __PACKAGE__); }
}


package main;

MAIN:
{
    my (@j, @result, $method);

    $method = My::Class->can('foo');
    ok($method                                 => 'My::Class->foo()');
    is(My::Class->foo(),     'My::Class->foo'  => 'Direct My::Class->foo()');
    is(My::Class->$method(), 'My::Class->foo'  => 'Indirect My::Class->foo()');

    $method = My::Sub->can('foo');
    ok($method                             => 'My::Sub->foo()');
    is(My::Sub->foo(),     'My::Sub->foo'  => 'Direct My::Sub->foo()');
    is(My::Sub->$method(), 'My::Sub->foo'  => 'Indirect My::Sub->foo()');

    $method = My::Sub->can('bar');
    ok($method                             => 'My::Sub->bar()');
    is(My::Sub->bar(),     'My::Sub->bar'  => 'Direct My::Sub->bar()');
    is(My::Sub->$method(), 'My::Sub->bar'  => 'Indirect My::Sub->bar()');

    $method = Bar->can('foo');
    ok($method                     => 'Bar can foo()');
    is(Bar->foo(),     'Bar->foo'  => 'Direct Bar->foo()');
    is(Bar->$method(), 'Bar->foo'  => 'Indirect Bar->foo()');

    $method = Bar->can('bar');
    ok($method                     => 'Bar can bar()');
    is(Bar->bar(),     'Bar->bar'  => 'Direct Bar->bar()');
    is(Bar->$method(), 'Bar->bar'  => 'Indirect Bar->bar()');

    $method = Baz->can('foo');
    ok($method                     => 'Baz can foo()');
    is(Baz->foo(),     'Baz->foo'  => 'Direct Baz->foo()');
    is(Baz->$method(), 'Baz->foo'  => 'Indirect Baz->foo()');

    $method = Baz->can('bar');
    ok($method                     => 'Baz can bar()');
    is(Baz->bar(),     'Baz->bar'  => 'Direct Baz->bar()');
    is(Baz->$method(), 'Baz->bar'  => 'Indirect Baz->bar()');

    $method = My::MT->can('foo');
    ok(!$method              => 'My::MT no can foo()');
    eval { My::MT->foo() };
    ok($@                    => 'No My::MT foo()');

    my $x = My::Class->new();
    @j = $x->jinx();
    @result = qw(My::Class->jinx);
    is_deeply(\@j, \@result, 'Class cumulative');

    my $z = My::Sub->new();
    @j = $z->jinx();
    @result = qw(My::Sub->jinx My::Class->jinx);
    is_deeply(\@j, \@result, 'Subclass cumulative');

    is($x->dummy(), 'My::Class->dummy', 'Class automethod');
    is($z->zebra(), 'My::Sub->zebra', 'Sublass automethod');

    my $y = $x->can('turtle');
    is($x->$y, 'My::Class->turtle', 'Class can+automethod');

    $y = $z->can('snort');
    is($z->$y, 'My::Sub->snort', 'Sublass can+automethod');

    my $obj = Bar->new();
    @j = $obj->jinx();
    @result = qw(My::Class->jinx);
    is_deeply(\@j, \@result, 'Inherited cumulative');

    $obj = Bar->new();
    is($obj->foom(), 'Bar->foom', 'Object automethod');

    $obj = Baz->new();
    is($obj->foom(), 'Baz->foom', 'Object automethod');
}

exit(0);

# EOF
