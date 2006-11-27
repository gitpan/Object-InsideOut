package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

my %CUMULATIVE;
my %ANTICUMULATIVE;
my %RESTRICT;
my $UNIV_ISA;

sub generate_CUMULATIVE :Sub(Private)
{
    my ($cum, $anticum, $TREE_TOP_DOWN, $TREE_BOTTOM_UP, $u_isa) = @_;

    $UNIV_ISA = $u_isa;

    # Get names for :CUMULATIVE methods
    my (%cum_loc);
    foreach my $package (keys(%{$cum})) {
        while (my $info = shift(@{$$cum{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CUMULATIVE', $location);
            $CUMULATIVE{$name}{$package} = $code;
            $cum_loc{$name}{$package} = $location;
            if ($restrict) {
                $RESTRICT{$package}{$name} = 1;
            }
        }
    }

    # Get names for :CUMULATIVE(BOTTOM UP) methods
    foreach my $package (keys(%{$anticum})) {
        while (my $info = shift(@{$$anticum{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CUMULATIVE(BOTTOM UP)', $location);

            # Check for conflicting definitions of $name
            if ($CUMULATIVE{$name}) {
                foreach my $other_package (keys(%{$CUMULATIVE{$name}})) {
                    if ($other_package->$UNIV_ISA($package) ||
                        $package->$UNIV_ISA($other_package))
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

            $ANTICUMULATIVE{$name}{$package} = $code;
            if ($restrict) {
                $RESTRICT{$package}{$name} = 1;
            }
        }
    }

    # Propagate restrictions
    my $reapply = 1;
    while ($reapply) {
        $reapply = 0;

        foreach my $pkg (keys(%RESTRICT)) {
            foreach my $class (keys(%{$TREE_TOP_DOWN})) {
                if (grep { $_ eq $pkg } @{$$TREE_TOP_DOWN{$class}}) {
                    foreach my $p (@{$$TREE_TOP_DOWN{$class}}) {
                        foreach my $n (keys(%{$RESTRICT{$pkg}})) {
                            if (! exists($RESTRICT{$p}{$n})) {
                                $RESTRICT{$p}{$n} = 1;
                                $reapply = 1;
                            }
                        }
                    }
                }
            }
        }
    }

    no warnings 'redefine';
    no strict 'refs';

    # Implement :CUMULATIVE methods
    foreach my $name (keys(%CUMULATIVE)) {
        my $code = create_CUMULATIVE($name, $TREE_TOP_DOWN, $CUMULATIVE{$name});
        foreach my $package (keys(%{$CUMULATIVE{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'cumulative');
            if ($RESTRICT{$package}{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }

    # Implement :CUMULATIVE(BOTTOM UP) methods
    foreach my $name (keys(%ANTICUMULATIVE)) {
        my $code = create_CUMULATIVE($name, $TREE_BOTTOM_UP, $ANTICUMULATIVE{$name});
        foreach my $package (keys(%{$ANTICUMULATIVE{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'cumulative (bottom up)');
            if ($RESTRICT{$package}{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }
}


# Returns a closure back to initialize() that is used to setup CUMULATIVE
# and CUMULATIVE(BOTTOM UP) methods for a particular method name.
sub create_CUMULATIVE :Sub(Private)
{
    # $name      - method name
    # $tree      - ref to either %TREE_TOP_DOWN or %TREE_BOTTOM_UP
    # $code_refs - hash ref by package of code refs for a particular method name
    my ($name, $tree, $code_refs) = @_;

    return sub {
        my $class = ref($_[0]) || $_[0];
        my $list_context = wantarray;
        my (@results, @classes);

        # Caller must be in class hierarchy
        if ($RESTRICT{$class}{$name}) {
            my $caller = caller();
            if (! ($caller->$UNIV_ISA($class) || $class->$UNIV_ISA($caller))) {
                OIO::Method->die('message' => "Can't call restricted method '$class->$name' from class '$caller'");
            }
        }

        # Accumulate results
        foreach my $pkg (@{$$tree{$class}}) {
            if (my $code = $$code_refs{$pkg}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
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

our $VERSION = 2.24;

use Object::InsideOut 2.24;
use Object::InsideOut::Metadata 2.24;

my @VALUES  :Field :Arg(VALUES);
my @CLASSES :Field :Arg(CLASSES);
my @HASHES  :Field;

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

# Our metadata
add_meta(__PACKAGE__, {
    'new'          => {'hidden' => 1},
    'create_field' => {'hidden' => 1},
    'add_class'    => {'hidden' => 1},
});

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.24;
($Object::InsideOut::VERSION == 2.24) or die("Version mismatch\n");
