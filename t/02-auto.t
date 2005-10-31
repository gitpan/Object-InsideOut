use strict;
use warnings;

use Test::More tests => 6;

package My::Class; {
    use Object::InsideOut;

    sub jinx : Cumulative(bottom up);

    sub auto : Automethod
    {
        my $name = $_;
        return sub {
                        my $self = $_[0];
                        my $class = ref($self) || $self;
                        return "AUTO: $class->$name";
                   };
    };

    sub jinx
    {
        return "My::Class->jinx";
    }
}


package My::Sub; {
    use Object::InsideOut qw(My::Class);

    sub jinx : Cumulative(bottom up)
    {
        return "My::Sub->jinx";
    }
}


package main;

MAIN:
{
    my (@j, @result);

    my $x = My::Class->new();
    @j = $x->jinx();
    @result = qw(My::Class->jinx);
    is_deeply(\@j, \@result, 'Class cumulative');

    my $z = My::Sub->new();
    @j = $z->jinx();
    @result = qw(My::Sub->jinx My::Class->jinx);
    is_deeply(\@j, \@result, 'Subclass cumulative');

    is($x->dummy(), 'AUTO: My::Class->dummy', 'Class automethod');
    is($z->zebra(), 'AUTO: My::Sub->zebra', 'Sublass automethod');

    my $y = $x->can('turtle');
    is($y->($x), 'AUTO: My::Class->turtle', 'Class can+automethod');

    $y = $z->can('snort');
    is($y->($z), 'AUTO: My::Sub->snort', 'Sublass can+automethod');
}

exit(0);

# EOF
