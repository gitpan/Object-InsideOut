use strict;
use warnings;

use lib 't';

use Test::More 'no_plan';

package Foo; {
    use Object::InsideOut;
}

package Bar; {
    use Object::InsideOut q/:Restricted(Zork, '')/, 'Foo';
}

package Baz; {
    use Object::InsideOut qw/:Private('Zork') Bar/;

    sub bar :Sub { return (Bar->new()); }
    sub baz :Sub { return (Baz->new()); }
}

package Ork; {
    use Object::InsideOut qw/:Public Baz/;
}

package Zork; {
    sub bar { return (Bar->new()); }
    sub baz { return (Baz->new()); }
}

package main;

MAIN:
{
    isa_ok(Foo->new(), 'Foo'            => 'Public class from main');

    eval { my $obj = Bar->new(); };
    like($@, qr/restricted method/      => 'Restricted class from main');

    eval { my $obj = Baz->new(); };
    like($@, qr/private method/         => 'Private class from main');

    isa_ok(Baz::bar(), 'Bar'            => 'Restricted class in hierarchy');
    isa_ok(Baz::baz(), 'Baz'            => 'Private class in class');

    isa_ok(Zork::bar(), 'Bar'           => 'Restricted class exemption');
    isa_ok(Zork::baz(), 'Baz'           => 'Private class exemption');

    isa_ok(Ork->new(), 'Ork'            => 'Public class from main');
}

# EOF
