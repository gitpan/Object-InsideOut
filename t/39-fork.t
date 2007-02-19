use strict;
use warnings;

BEGIN {
    if ($^O ne 'MSWin32') {
        print("1..0 # Skip Not MSWin32\n");
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
