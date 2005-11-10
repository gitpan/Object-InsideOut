use strict;
use warnings;

use Test::More 'no_plan';

BEGIN {
    use_ok('Object::InsideOut');
}

if (Object::InsideOut->VERSION) {
    diag('Testing Object::InsideOut ' . Object::InsideOut->VERSION);
}

# EOF
