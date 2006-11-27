package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

my %CHAINED;
my %ANTICHAINED;
my %RESTRICT;
my $UNIV_ISA;

sub generate_CHAINED :Sub(Private)
{
    my ($chain, $antichain, $TREE_TOP_DOWN, $TREE_BOTTOM_UP, $u_isa) = @_;

    $UNIV_ISA = $u_isa;

    # Get names for :CHAINED methods
    my (%chain_loc);
    foreach my $package (keys(%{$chain})) {
        while (my $info = shift(@{$$chain{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CHAINED', $location);
            $CHAINED{$name}{$package} = $code;
            $chain_loc{$name}{$package} = $location;
            if ($restrict) {
                $RESTRICT{$package}{$name} = 1;
            }
        }
    }

    # Get names for :CHAINED(BOTTOM UP) methods
    my (%antichain, %antichain_restrict);
    foreach my $package (keys(%{$antichain})) {
        while (my $info = shift(@{$$antichain{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CHAINED(BOTTOM UP)', $location);

            # Check for conflicting definitions of $name
            if ($CHAINED{$name}) {
                foreach my $other_package (keys(%{$CHAINED{$name}})) {
                    if ($other_package->$UNIV_ISA($package) ||
                        $package->$UNIV_ISA($other_package))
                    {
                        my ($pkg,  $file,  $line)  = @{$chain_loc{$name}{$other_package}};
                        my ($pkg2, $file2, $line2) = @{$location};
                        OIO::Attribute->die(
                            'location' => $location,
                            'message'  => "Conflicting definitions for chained method '$name'",
                            'Info'     => "Declared as :CHAINED in class '$pkg' (file '$file', line $line), but declared as :CHAINED(BOTTOM UP) in class '$pkg2' (file '$file2' line $line2)");
                    }
                }
            }

            $ANTICHAINED{$name}{$package} = $code;
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

    # Implement :CHAINED methods
    foreach my $name (keys(%CHAINED)) {
        my $code = create_CHAINED($name, $TREE_TOP_DOWN, $CHAINED{$name});
        foreach my $package (keys(%{$CHAINED{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'chained');
            if ($RESTRICT{$package}{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }

    # Implement :CHAINED(BOTTOM UP) methods
    foreach my $name (keys(%ANTICHAINED)) {
        my $code = create_CHAINED($name, $TREE_BOTTOM_UP, $ANTICHAINED{$name});
        foreach my $package (keys(%{$ANTICHAINED{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'chained (bottom up)');
            if ($RESTRICT{$package}{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }
}


# Returns a closure back to initialize() that is used to setup CHAINED
# and CHAINED(BOTTOM UP) methods for a particular method name.
sub create_CHAINED :Sub(Private)
{
    # $name      - method name
    # $tree      - ref to either %TREE_TOP_DOWN or %TREE_BOTTOM_UP
    # $code_refs - hash ref by package of code refs for a particular method name
    my ($name, $tree, $code_refs) = @_;

    return sub {
        my $thing = shift;
        my $class = ref($thing) || $thing;
        my @args = @_;
        my $list_context = wantarray;
        my @classes;

        # Caller must be in class hierarchy
        if ($RESTRICT{$class}{$name}) {
            my $caller = caller();
            if (! ($caller->$UNIV_ISA($class) || $class->$UNIV_ISA($caller))) {
                OIO::Method->die('message' => "Can't call restricted method '$class->$name' from class '$caller'");
            }
        }

        # Chain results together
        foreach my $pkg (@{$$tree{$class}}) {
            if (my $code = $$code_refs{$pkg}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
                @args = $thing->$code(@args);
                push(@classes, $pkg);
            }
        }

        # Return results
        return (@args);
    };
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.24;
($Object::InsideOut::VERSION == 2.24) or die("Version mismatch\n");
