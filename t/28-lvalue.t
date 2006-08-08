use strict;
use warnings;

BEGIN {
    if ($] < 5.008) {
        print("1..0 # Skip :lvalue requires Perl 5.8.0 or later\n");
        exit(0);
    }
    eval { require Want; };
    if ($@) {
        print("1..0 # Skip The 'Want' module is not available\n");
        exit(0);
    }
}

use Test::More 'no_plan';

package Foo; {
    use Object::InsideOut;

    my @name  :Field('lvalue' => 'name');
    my %rank  :Field('Std' => 'rank', 'LValue' => 1, 'Return' => 'Self');
    my @snum  :Field('Acc' => 'snum', 'lv' => 1, 'Type' => 'Num');
    my @email :Field('lvalue' => 'email', 'Return' => 'Old');

    my %init_args :InitArgs = (
        'name'  => { 'FIELD' => \@name, },
        'rank'  => { 'FIELD' => \%rank, },
        'snum'  => { 'FIELD' => \@snum, },
        'email' => { 'FIELD' => \@email }
    );
}

package main;

sub change_it
{
    $_[0] = $_[1];
}

sub check_it
{
    my ($x, $y) = @_;
    if ($x eq $y) {
        ok(1, 'Checked');
    } else {
        is($x, $y, 'Check failed');
    }
}

MAIN:
{
    my $obj = Foo->new({
        name => 'Frank',
        rank => 'Private',
        snum => '12345',
        email => 'frank@army.org',
    });
    ok($obj, 'Object created');
    can_ok($obj, qw(new clone DESTROY CLONE name get_rank set_rank snum));

    eval { $obj->name(); };
    ok(! $@                             => 'rvalue void context');

    my $name = $obj->name();
    is($name, 'Frank'                   => 'rvalue assign');

    change_it($obj->name(), 'Fred');
    is($obj->name(), 'Fred'             => 'lvalue not assign');
    check_it($obj->name(), 'Fred');

    $name = $obj->name('Pete');
    is($name, 'Pete'                    => 'rvalue assign args');

    $obj->name('Sam');
    is($obj->name(), 'Sam'              => 'rvalue args');

    $obj->name() = 'John';
    is($obj->name(), 'John'             => 'lvalue assign');

    change_it($obj->name('Buck'), 'Fred');
    is($obj->name(), 'Fred'             => 'lvalue not assign args');

    $obj->name() =~ s/re/er/;
    is($obj->name(), 'Ferd'             => 'lvalue re');


    eval { $obj->set_rank(); };
    like($@, qr/Missing arg/            => 'rvalue void context');

    change_it($obj->set_rank(), 'Seaman');
    is($obj->get_rank(), 'Seaman'       => 'lvalue not assign');

    my $obj2 = $obj->set_rank('Airman');
    is($obj2->get_rank(), 'Airman'      => 'rvalue assign args');

    $obj->set_rank('Ensign');
    is($obj2->get_rank(), 'Ensign'      => 'rvalue args');

    $obj->set_rank() = 'General';
    is($obj2->get_rank(), 'General'     => 'lvalue assign');

    change_it($obj->set_rank('Private'), 'Major');
    is($obj2->get_rank(), 'Major'       => 'lvalue not assign args');

    my $rank = (my $dummy=$obj->set_rank('Captain'))->get_rank();
    is($rank, 'Captain'                 => 'lvalue chain');


    eval { $obj->snum(); };
    ok(! $@                             => 'rvalue void context');

    my $snum = $obj->snum();
    is($snum, 12345                     => 'rvalue assign');

    change_it($obj->snum(), 47);
    is($obj->snum(), 47                 => 'lvalue not assign');

    $snum = $obj->snum(999);
    is($snum, 999                       => 'rvalue assign args');

    $obj->snum(12);
    is($obj->snum(), 12                 => 'rvalue args');

    eval { $obj->snum() = 'John'; };
    like($@, qr/must be numeric/        => 'type check');

    $obj->snum() = 9876;
    is($obj->snum(), 9876               => 'lvalue assign');

    change_it($obj->snum(44), 86);
    is($obj->snum(), 86                 => 'lvalue not assign args');

    my $old_email = $obj->email('fred@navy.gov');
    is($old_email, 'frank@army.org'     => 'Old value');
    is($obj->email(), 'fred@navy.gov'   => 'New value');

    $old_email = $obj->email() = 'pete@marines.net';
    is($old_email, 'pete@marines.net'   => 'Old value');
    is($obj->email(), 'pete@marines.net' => 'New value');

    is($obj->email(), 'pete@marines.net' => 'Old value');
    is($obj->email('x@y.z'), 'x@y.z'    => 'New value');
}

exit(0);

# EOF
