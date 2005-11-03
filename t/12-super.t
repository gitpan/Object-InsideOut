use strict;
use warnings;

use Test::More 'no_plan';

package My::Class; {
    use Object::InsideOut;

    sub auto : Automethod
    {
        return;
    }

    sub foo { 1 }
}

package My::Sub; {
    use Object::InsideOut qw(My::Class);

    Test::More::is(My::Sub->can('foo'), My::Sub->can('SUPER::foo')
                            => q/->can('SUPER::method')/);
}

# EOF
