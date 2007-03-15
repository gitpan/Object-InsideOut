use strict;
use warnings;

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

for (1..3) {
    if (my $pid = fork()) {
        $obj->foo($_);
        die if $obj->foo() != $_;
    } else {
        $obj->foo($_);
        die if $obj->foo() != $_;
    }
}

ok(1, "MSWin32 pseudo-forks") if ($$ == $main);

# EOF
