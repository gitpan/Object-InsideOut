use strict;
use warnings;

use Test::More 'no_plan';

# Borg is a foreign hash-based class
package Borg; {
    sub new
    {
        my $class = shift;
        my %self = @_;
        return (bless(\%self, $class));
    }

    sub get_borg
    {
        my ($self, $data) = @_;
        return ($self->{$data});
    }

    sub set_borg
    {
        my ($self, $key, $value) = @_;
        $self->{$key} = $value;
    }

    sub warn
    {
        return ('Resistance is futile');
    }

    sub DESTROY {}
}


package Foo; {
    use Object::InsideOut qw(Borg);

    my @objs :Field('Acc'=>'obj', 'Type' => 'list');

    my %init_args :InitArgs = (
        'OBJ' => {
            'RE'    => qr/^obj$/i,
            'Field' => \@objs,
            'Type'  => 'list',
        },
        'BORG' => {
            'RE'    => qr/^borg$/i,
        }
    );

    sub init :Init
    {
        my ($self, $args) = @_;

        my $borg = Borg->new();
        $self->inherit($borg);

        if (exists($args->{'BORG'})) {
            $borg->set_borg('borg' => $args->{'BORG'});
        }
    }

    sub unborg
    {
        my $self = $_[0];
        #if (my $borg = $self->heritage('Borg')) {
        #    $self->disinherit($borg);
        #}
        $self->disinherit('Borg');
    }
}

package Bar; {
    use Object::InsideOut qw(Foo);
}

package Baz; {
    use Object::InsideOut qw(Bar);
}


package main;
MAIN:
{
    can_ok('Borg'                       => qw(get_borg set_borg));
    ok(Foo->isa('Borg')                 => 'Foo isa Borg');
    can_ok('Foo'                        => qw(unborg get_borg set_borg));
    is(Foo->warn(), 'Resistance is futile' => 'Class method inheritance');

    my $obj = Baz->new('borg' => 'Picard');

    ok($obj->isa('Foo')                 => 'isa Foo');
    ok($obj->isa('Borg')                => 'isa Borg');
    can_ok($obj                         => qw(get_borg set_borg unborg obj));
    is($obj->get_borg('borg'), 'Picard' => 'get from Borg');

    $obj->set_borg('borg' => '1 of 5');
    is($obj->get_borg('borg'), '1 of 5' => 'Changed Borg');

    my $obj2 = Baz->new('obj'=>$obj);
    ok($obj2->isa('Borg')               => 'isa Borg');

    my ($x) = @{$obj2->obj()};
    is($x, $obj                         => 'Retrieved object');

    $obj->unborg();
    ok($obj->isa('Foo')                 => 'isa Foo');
    ok(! $obj->isa('Borg')              => 'no longer a Borg');
}

exit(0);

# EOF
