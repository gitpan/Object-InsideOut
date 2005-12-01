use strict;
use warnings;

use Test::More 'no_plan';

package My::Class; {
    use Object::InsideOut;


    sub auto : Automethod
    {
        my $self = $_[0];
        my $class = ref($self) || $self;

        my $method = $_;

        my ($fld_name) = $method =~ /^[gs]et_(.*)$/;
        if (! $fld_name) {
            return;
        }
        Object::InsideOut->create_field($class, '@'.$fld_name,
                                        "'Name'=>'$fld_name',
                                         'Std' =>'$fld_name'");

        no strict 'refs';
        return *{$class.'::'.$method}{'CODE'};
    }
}


package My::Sub; {
    use Object::InsideOut qw(My::Class);

    my @data :Field('set'=>'munge');
}


package main;

MAIN:
{
    my $obj = My::Sub->new();

    $obj->set_data(5);
    can_ok($obj, qw(get_data set_data));
    is($obj->get_data(), 5              => 'Method works');
    can_ok('My::Sub', qw(get_data set_data));
    $obj->munge('hello');
    is($obj->get_data(), 5              => 'Not munged');
    #print(STDERR $obj->dump(1), "\n");
}

exit(0);

# EOF
