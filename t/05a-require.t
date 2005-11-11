use strict;
use warnings;

use Test::More 'no_plan';

eval {
    require "t/05a-require.pm";
};
ok(! $@, 'require ' . $@);


package main;

MAIN:
{
    my $obj;
    eval { $obj = AA->new(); };
    ok(! $@, '->new() ' . $@);
    can_ok($obj, qw(new clone DESTROY CLONE aa));

    is($$obj, 1,                    'Object ID: ' . $$obj);
    ok(! defined($obj->aa),         'No default');
    is($obj->aa(42), 42,            'Set ->aa()');
    is($obj->aa, 42,                'Get ->aa()');

    eval { $obj = BB->new(); };
    can_ok($obj, qw(bb set_bb));
    ok(! $@, '->new() ' . $@);
    is($$obj, 2,                    'Object ID: ' . $$obj);
    is($obj->bb, 'def',             'Default: ' . $obj->bb);
    is($obj->set_bb('foo'), 'foo',  'Set ->set_bb()');
    is($obj->bb, 'foo',             'Get ->bb() eq ' . $obj->bb);

    eval { $obj = BB->new('bB' => 'baz'); };
    ok(! $@, '->new() ' . $@);
    is($$obj, 3,                    'Object ID: ' . $$obj);
    is($obj->bb, 'baz',             'Init: ' . $obj->bb);
    is($obj->set_bb('foo'), 'foo',  'Set ->set_bb()');
    is($obj->bb, 'foo',             'Get ->bb() eq ' . $obj->bb);

    eval { $obj = AB->new(); };
    can_ok($obj, qw(aa bb set_bb data info_get info_set));
    ok(! $@, '->new() ' . $@);
    is($$obj, 4,                    'Object ID: ' . $$obj);
    is($obj->bb, 'def',             'Default: ' . $obj->bb);
    is($obj->set_bb('foo'), 'foo',  'Set ->set_bb()');
    is($obj->bb, 'foo',             'Get ->bb() eq ' . $obj->bb);
}

exit(0);

# EOF
