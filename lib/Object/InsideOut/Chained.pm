package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

sub generate_CHAINED :Sub(Private)
{
    my ($CHAINED,       $ANTICHAINED,
        $TREE_TOP_DOWN, $TREE_BOTTOM_UP, $u_isa) = @_;

    # Get names for :CHAINED methods
    my (%chain, %chain_loc, %chain_restrict);
    foreach my $package (keys(%{$CHAINED})) {
        while (my $info = shift(@{$$CHAINED{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CHAINED', $location);
            $chain{$name}{$package} = $code;
            $chain_loc{$name}{$package} = $location;
            if ($restrict) {
                $chain_restrict{$name} = $u_isa;
            }
        }
    }

    # Get names for :CHAINED(BOTTOM UP) methods
    my (%antichain, %antichain_restrict);
    foreach my $package (keys(%{$ANTICHAINED})) {
        while (my $info = shift(@{$$ANTICHAINED{$package}})) {
            my ($code, $location, $name, $restrict) = @{$info};
            $name ||= sub_name($code, ':CHAINED(BOTTOM UP)', $location);

            # Check for conflicting definitions of $name
            if ($chain{$name}) {
                foreach my $other_package (keys(%{$chain{$name}})) {
                    if ($other_package->$u_isa($package) ||
                        $package->$u_isa($other_package))
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

            $antichain{$name}{$package} = $code;
            if ($restrict) {
                $antichain_restrict{$name} = $u_isa;
            }
        }
    }

    no warnings 'redefine';
    no strict 'refs';

    # Implement :CHAINED methods
    foreach my $name (keys(%chain)) {
        my $code = create_CHAINED($TREE_TOP_DOWN, $chain{$name}, $chain_restrict{$name}, $name);
        foreach my $package (keys(%{$chain{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'chained');
            if ($chain_restrict{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }

    # Implement :CHAINED(BOTTOM UP) methods
    foreach my $name (keys(%antichain)) {
        my $code = create_CHAINED($TREE_BOTTOM_UP, $antichain{$name}, $antichain_restrict{$name}, $name);
        foreach my $package (keys(%{$antichain{$name}})) {
            *{$package.'::'.$name} = $code;
            add_meta($package, $name, 'kind', 'chained (bottom up)');
            if ($antichain_restrict{$name}) {
                add_meta($package, $name, 'restricted', 1);
            }
        }
    }
}


# Returns a closure back to initialize() that is used to setup CHAINED
# and CHAINED(BOTTOM UP) methods for a particular method name.
sub create_CHAINED :Sub(Private)
{
    # $tree      - ref to either %TREE_TOP_DOWN or %TREE_BOTTOM_UP
    # $code_refs - hash ref by package of code refs for a particular method name
    # $restrict  - restricted method (trick: == $UNIV_ISA)
    # $name      - method name
    my ($tree, $code_refs, $restrict, $name) = @_;

    return sub {
        my $thing = shift;
        my $class = ref($thing) || $thing;
        my @args = @_;
        my $list_context = wantarray;
        my @classes;

        # Caller must be in class hierarchy
        if ($restrict) {
            my $caller = caller();
            if (! ($caller->$restrict($class) || $class->$restrict($caller))) {
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
my $VERSION = 2.22;
($Object::InsideOut::VERSION == 2.22) or die("Version mismatch\n");
