use strict;
use warnings;

use Test::More 'no_plan';

package Foreign::Exception; {
    use Exception::Class (
        'Foreign::Exception::Base' => {
            description => 'Generic exception base class',
        },
    );
}

package Foo; {
    use Object::InsideOut;

    my @init :Field;
    my @dest :Field;

    my %init_args :InitArgs = (
        'NEW' => {
            'DEFAULT' => 1,
        },
        'INIT' => {
            'FIELD' => \@init,
        },
        'DEST'  => {
            'FIELD' => \@dest,
        },
    );

    sub _init :Init
    {
        my $self = shift;
        if ($init[$$self]) {
            die("Die in init\n");
        }
        return;
    }

    sub _destroy :Destroy
    {
        my $self = shift;
        if ($dest[$$self]) {
            die("Die in destruct\n");
        }
        return;
    }

}

package main;

my @errs;
$SIG{__WARN__} = sub { push(@errs, @_); };

{
    my $obj = eval { Foo->new(); };
    isa_ok($obj, 'Foo', 'Object');
    ok(! @errs, 'No warnings');
    undef($@); @errs = ();
}

{
    my $obj = eval { Foo->new('INIT' => 1); };
    ok(! $obj, 'No object');
    like($@->Error(), qr/^Die in init/, 'Die in init');
    ok(! @errs, 'No warnings');
    undef($@); @errs = ();
}

{
    my $obj = Foo->new('DEST' => 1);
    ok($obj && !$@ && !@errs, 'Have object');
    undef($obj);
    like($@, qr/Die in destruct/, 'Die in destroy');
    like($errs[0], qr/Die in destruct/, 'Die in destroy warning');
    undef($@); @errs = ();
}

{
    my $obj = eval { Foo->new('INIT' => 1, 'DEST' => 1); };
    ok(! $obj, 'No object');
    like($@->Error(), qr/Die in init/, 'Die in init');
    like($@->Chain()->Error(), qr/Die in destruct/, 'Combined errors');
    ok(! @errs, 'No warnings');
    undef($@); @errs = ();
}

{
    my $obj = eval {
        my $x = Foo->new();
        Foreign::Exception::Base->throw('error' => 'Aborted');
        $x;
    };
    ok(! $obj, 'No object');
    is($@->error(), 'Aborted', 'Aborted');
    ok(! @errs, 'No warnings');
    undef($@); @errs = ();
}

{
    my $obj = eval {
        my $x = Foo->new('DEST' => 1);
        Foreign::Exception::Base->throw('error' => 'Aborted');
        $x;
    };
    ok(! $obj, 'No object');
    is($@->error(), 'Aborted', 'Aborted');
    like($errs[0], qr/Die in destruct/, 'Die in destroy warning');
    undef($@); @errs = ();
}

exit(0);

# EOF
