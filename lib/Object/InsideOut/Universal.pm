package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Install versions of UNIVERSAL::can/isa that understands :Automethod and
# foreign inheritance
sub install_UNIVERSAL
{
    # $u_isa          - ref to the orginal UNIVERSAL::isa()
    # $u_can          - ref to the orginal UNIVERSAL::can()
    # $AUTOMETHODS    - ref to %AUTOMETHODS
    # $HERITAGE       - ref to %HERITAGE
    # $TREE_BOTTOM_UP - ref to %TREE_BOTTOM_UP
    my ($u_isa, $u_can, $AUTOMETHODS, $HERITAGE, $TREE_BOTTOM_UP) = @_;

    *UNIVERSAL::can = sub
    {
        my ($thing, $method) = @_;

        # First, try the original UNIVERSAL::can()
        my $code;
        if ($method =~ /^SUPER::/) {
            # Superclass WRT caller
            my $caller = caller();
            $code = $u_can->($thing, $caller.'::'.$method);
        } else {
            $code = $u_can->($thing, $method);
        }
        if ($code) {
            return ($code);
        }

        # Handle various calling methods
        my ($class, $super);
        if ($method !~ /::/) {
            # Ordinary method check
            #   $obj->can('x');
            $class = ref($thing) || $thing;

        } elsif ($method !~ /SUPER::/) {
            # Fully-qualified method check
            #   $obj->can('FOO::x');
            ($class, $method) = $method =~ /^(.+)::([^:]+)$/;

        } elsif ($method =~ /^SUPER::/) {
            # Superclass method check
            #   $obj->can('SUPER::x');
            $class = caller();
            $method =~ s/SUPER:://;
            $super = 1;

        } else {
            # Qualified superclass method check
            #   $obj->can('Foo::SUPER::x');
            ($class, $method) = $method =~ /^(.+)::SUPER::([^:]+)$/;
            $super = 1;
        }

        # Next, check with heritage objects and Automethods
        foreach my $package (@{$$TREE_BOTTOM_UP{$class}}) {
            # Skip self's class if SUPER
            if ($super && $class eq $package) {
                next;
            }

            # Check heritage
            if (exists($$HERITAGE{$package})) {
                foreach my $pkg (keys(%{$$HERITAGE{$package}[1]})) {
                    if ($code = $pkg->$u_can($method)) {
                        return ($code);
                    }
                }
            }

            # Check with the Automethods
            if (my $automethod = $$AUTOMETHODS{$package}) {
                # Call the Automethod to get a code ref
                local $CALLER::_ = $_;
                local $_ = $method;
                local $SIG{'__DIE__'} = 'OIO::trap';
                if ($code = $thing->$automethod()) {
                    return ($code);
                }
            }
        }

        return;   # Can't
    };


    *UNIVERSAL::isa = sub
    {
        my ($thing, $type) = @_;

        # First, try the original UNIVERSAL::isa()
        my $isa = $thing->$u_isa($type);
        if ($isa) {
            return ($isa);
        }

        # Next, check heritage
        foreach my $package (@{$$TREE_BOTTOM_UP{ref($thing) || $thing}}) {
            if (exists($$HERITAGE{$package})) {
                foreach my $pkg (keys(%{$$HERITAGE{$package}[1]})) {
                    if ($isa = $pkg->$u_isa($type)) {
                        return ($isa);
                    }
                }
            }
        }

        return ('');   # Isn't
    };


    # Stub ourself out
    *Object::InsideOut::install_UNIVERSAL = sub { };
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 1.51;
($Object::InsideOut::VERSION == 1.51) or die("Version mismatch\n");
