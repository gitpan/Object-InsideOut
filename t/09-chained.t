use strict;
use warnings;

use Test::More 'no_plan';

package Base1; {
    use Object::InsideOut;

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package Base2; {
    use Object::InsideOut qw(Base1);

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package Base3; {
    use Object::InsideOut qw(Base1);

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package Base4; {
    use Object::InsideOut;

    sub base_first                     { shift; return(@_, __PACKAGE__); }
    sub der_first                      { shift; return(@_, __PACKAGE__); }
}

package Der1; {
    use Object::InsideOut qw(Base2 Base3 Base4);

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package Der2; {
    use Object::InsideOut qw(Base2 Base3 Base4);

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package Reder1; {
    use Object::InsideOut qw(Der1 Der2);

    sub base_first :Chained            { shift; return(@_, __PACKAGE__); }
    sub der_first  :Chained(bottom up) { shift; return(@_, __PACKAGE__); }
}

package main;

MAIN:
{
    my $obj = Reder1->new();

    my $top_down = $obj->base_first();
    my $bot_up   = $obj->der_first();

    my @top_down = qw(Base1 Base2 Base3 Der1 Der2 Reder1);
    my @bot_up   = qw(Reder1 Der2 Der1 Base3 Base2 Base1);

    is_deeply(\@$top_down, \@top_down      => 'List chained down');
    is_deeply(\@$bot_up,   \@bot_up        => 'List chained up');

    is(int $bot_up,   int @bot_up          => 'Numeric chained up');
    is(int $top_down, int @top_down        => 'Numeric chained down');

    is("$bot_up",   join(q{}, @bot_up)     => 'String chained up');
    is("$top_down", join(q{}, @top_down)   => 'String chained down');

    for my $pkg (keys %$bot_up) {
        ok(grep($pkg, @bot_up)   => "Valid up hash key ($pkg)");
        is($pkg, $bot_up->{$pkg} => "Valid up hash value ($pkg)");
    }

    for my $pkg (keys %$top_down) {
        ok(grep($pkg, @top_down) => "Valid down hash key ($pkg)");
        is($pkg, $bot_up->{$pkg} => "Valid down hash value ($pkg)");
    }
}

exit(0);

# EOF
