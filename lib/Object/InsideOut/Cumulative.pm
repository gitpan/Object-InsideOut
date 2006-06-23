package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

sub generate_CUMULATIVE :Private
{
    my ($CUMULATIVE,    $ANTICUMULATIVE,
        $TREE_TOP_DOWN, $TREE_BOTTOM_UP, $u_isa) = @_;

    # Get names for :CUMULATIVE methods
    my (%cum, %cum_loc);
    foreach my $package (keys(%{$CUMULATIVE})) {
        foreach my $info (@{$$CUMULATIVE{$package}}) {
            my ($code, $location) = @{$info};
            my $name = sub_name($code, ':CUMULATIVE', $location);
            $cum{$name}{$package} = $code;
            $cum_loc{$name}{$package} = $location;
        }
    }

    # Get names for :CUMULATIVE(BOTTOM UP) methods
    my %anticum;
    foreach my $package (keys(%{$ANTICUMULATIVE})) {
        foreach my $info (@{$$ANTICUMULATIVE{$package}}) {
            my ($code, $location) = @{$info};
            my $name = sub_name($code, ':CUMULATIVE(BOTTOM UP)', $location);

            # Check for conflicting definitions of $name
            if ($cum{$name}) {
                foreach my $other_package (keys(%{$cum{$name}})) {
                    if ($other_package->$u_isa($package) ||
                        $package->$u_isa($other_package))
                    {
                        my ($pkg,  $file,  $line)  = @{$cum_loc{$name}{$other_package}};
                        my ($pkg2, $file2, $line2) = @{$location};
                        OIO::Attribute->die(
                            'location' => $location,
                            'message'  => "Conflicting definitions for cumulative method '$name'",
                            'Info'     => "Declared as :CUMULATIVE in class '$pkg' (file '$file', line $line), but declared as :CUMULATIVE(BOTTOM UP) in class '$pkg2' (file '$file2' line $line2)");
                    }
                }
            }

            $anticum{$name}{$package} = $code;
        }
    }

    no warnings 'redefine';
    no strict 'refs';

    # Implement :CUMULATIVE methods
    foreach my $name (keys(%cum)) {
        my $code = create_CUMULATIVE($TREE_TOP_DOWN, $cum{$name});
        foreach my $package (keys(%{$cum{$name}})) {
            *{$package.'::'.$name} = $code;
        }
    }

    # Implement :CUMULATIVE(BOTTOM UP) methods
    foreach my $name (keys(%anticum)) {
        my $code = create_CUMULATIVE($TREE_BOTTOM_UP, $anticum{$name});
        foreach my $package (keys(%{$anticum{$name}})) {
            *{$package.'::'.$name} = $code;
        }
    }
}


# Returns a closure back to initialize() that is used to setup CUMULATIVE
# and CUMULATIVE(BOTTOM UP) methods for a particular method name.
sub create_CUMULATIVE :Private
{
    # $tree      - ref to either %TREE_TOP_DOWN or %TREE_BOTTOM_UP
    # $code_refs - hash ref by package of code refs for a particular method name
    my ($tree, $code_refs) = @_;

    return sub {
        my $class = ref($_[0]) || $_[0];
        my $list_context = wantarray;
        my (@results, @classes);

        # Accumulate results
        foreach my $pkg (@{$$tree{$class}}) {
            if (my $code = $$code_refs{$pkg}) {
                local $SIG{__DIE__} = 'OIO::trap';
                my @args = @_;
                if (defined($list_context)) {
                    push(@classes, $pkg);
                    if ($list_context) {
                        # List context
                        push(@results, $code->(@args));
                    } else {
                        # Scalar context
                        push(@results, scalar($code->(@args)));
                    }
                } else {
                    # void context
                    $code->(@args);
                }
            }
        }

        # Return results
        if (defined($list_context)) {
            if ($list_context) {
                # List context
                return (@results);
            }
            # Scalar context - returns object
            return (Object::InsideOut::Results->new('VALUES'  => \@results,
                                                    'CLASSES' => \@classes));
        }
    };
}

}  # End of package's lexical scope


package Object::InsideOut::Results; {

use strict;
use warnings;

use Object::InsideOut 1.43;

my @VALUES  :Field;
my @CLASSES :Field;
my @HASHES  :Field;

my %init_args :InitArgs = (
    'VALUES'  => { 'FIELD' => \@VALUES  },
    'CLASSES' => { 'FIELD' => \@CLASSES }
);

sub as_string :Stringify
{
    return (join('', grep { defined $_ } @{$VALUES[${$_[0]}]}));
}

sub count :Numerify
{
    return (scalar(@{$VALUES[${$_[0]}]}));
}

sub have_any :Boolify
{
    return (@{$VALUES[${$_[0]}]} > 0);
}

sub values :Arrayify
{
    return ($VALUES[${$_[0]}]);
}

sub as_hash :Hashify
{
    my $self = $_[0];

    if (! exists($HASHES[$$self])) {
        my %hash;
        @hash{@{$CLASSES[$$self]}} = @{$VALUES[$$self]};
        $self->set(\@HASHES, \%hash);
    }

    return ($HASHES[$$self]);
}

}  # End of package's lexical scope


# Ensure correct versioning
($Object::InsideOut::VERSION == 1.43) or die("Version mismatch\n");
