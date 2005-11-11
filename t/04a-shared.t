use strict;
use warnings;

use Config;
BEGIN {
    if (! $Config{useithreads} || $] < 5.008) {
        print("1..0 # Skip Threads not supported\n");
        exit(0);
    }
    if ($] == 5.008) {
        print("1..0 # Skip Thread sharing support not working for Perl 5.8.0\n");
        exit(0);
    }

    if ($^O eq 'Win32' && $] == 5.008004) {
        print("1..0 # Skip Thread support not working for ActivePerl 5.8.4\n");
        exit(0);
    }
}


use threads;
use threads::shared;

use Test::More 'no_plan';


package My::Obj; {
    use Object::InsideOut;

    my @x : Field({'accessor'=>'x'});
}


package My::Obj::Sub; {
    use Object::InsideOut ':SHARED', qw(My::Obj);

    my @y : Field({'accessor'=>'y'});
}


package main;

MAIN:
{
    my $obj = My::Obj->new();
    $obj->x(5);
    is($obj->x(), 5, 'Class set data');

    my $obj2 = My::Obj::Sub->new();
    $obj2->x(9);
    $obj2->y(3);
    is($obj2->x(), 9, 'Subclass set data');
    is($obj2->y(), 3, 'Subclass set data');

    my $rc = threads->create(
                        sub {
                            is($obj->x(), 5, 'Thread class data');
                            is($obj2->x(), 9, 'Thread subclass data');
                            is($obj2->y(), 3, 'Thread subclass data');

                            $obj->x([ 1, 2, 3]);
                            $obj2->x(99);
                            $obj2->y(3-1);

                            is_deeply($obj->x(), [ 1, 2, 3], 'Thread class data');
                            is($obj2->x(), 99, 'Thread subclass data');
                            is($obj2->y(), 2, 'Thread subclass data');

                            return (1);
                        }
                    )->join();

    is_deeply($obj->x(), [ 1, 2, 3], 'Thread class data');
    is($obj2->x(), 99, 'Thread subclass data');
    is($obj2->y(), 2, 'Thread subclass data');
}

exit(0);

# EOF
