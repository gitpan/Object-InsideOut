use strict;
use warnings;

BEGIN {
    if ($] == 5.008004 || $] == 5.008005) {
        my $z = ($] == 5.008004) ? 4 : 5;
        print("1..0 # Skip due to Perl 5.8.$z bug\n");
        exit(0);
    }
    eval {
        require Storable;
        Storable->import('thaw');
    };
    if ($@) {
        print("1..0 # Skip Storable not available\n");
        exit(0);
    }
}


use Test::More qw(no_plan);

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
    use Object::InsideOut qw(Bar Storable);
}


package Mat; {
    use Object::InsideOut qw(Storable);
    my @bom :Field( Standard => 'bom', Name => 'bom' );
}



package main;
MAIN:
{
    my $obj = Baz->new('borg' => 'Picard');

    my $x = $obj->freeze();
    my $obj2 = thaw($x);
    is($obj->dump(1), $obj2->dump(1) => 'Storable works');

    # Test circular reference case
    my $f1 = Mat->new();
    $f1->set_bom($f1);
    is($f1->get_bom(), $f1      => 'Stored object');

    my $f2 = thaw($f1->freeze());
    is($f2->get_bom(), $f2      => 'Freeze+Thaw');
}

exit(0);

# EOF
