use strict;
use warnings;
no warnings 'once';

BEGIN {
    use Config;
    unless ($^O eq 'MSWin32' || $Config{'d_pseudofork'}) {
        print("1..0 # Skip Not using pseudo-forks\n");
        exit(0);
    }
}

use Test::More 'tests' => 1;

package Foo; {
    use Object::InsideOut;

    my @foo :Field :All(foo);
}

package main;

my $main = $$;

my $obj = Foo->new();
$obj->foo(0);

open(OLDERR, ">&STDERR");
open(STDERR, ">stderr.tmp");

for (1..3) {
    if (my $pid = fork()) {
        # Parent
        $obj->foo($_);
        die if $obj->foo() != $_;

        my $x = Foo->new();
        $x->foo($$);
        die if $x->foo() != $$;

    } else {
        # Child
        $obj->foo($_);
        die if $obj->foo() != $_;

        my $x = Foo->new();
        $x->foo($$);
        die if $x->foo() != $$;
    }
}

if ($$ == $main) {
    sleep(2);
    open(STDERR, '>&OLDERR');
    ok(-z 'stderr.tmp', "MSWin32 pseudo-forks");
    if (-s 'stderr.tmp') {
        open(IN, 'stderr.tmp');
        diag($_) foreach (<IN>);
        close(IN);
    }
    unlink('stderr.tmp');
}

# EOF
