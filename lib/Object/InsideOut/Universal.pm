package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Install versions of UNIVERSAL::can/isa that understands :Automethod and
# foreign inheritance
sub install_UNIVERSAL
{
    my ($GBL) = @_;

    *UNIVERSAL::can = sub
    {
        my ($thing, $method) = @_;

        # Is it a metadata call?
        if (! $method) {
            my $meths = $thing->Object::InsideOut::meta()->get_methods();
            return (wantarray()) ? (keys(%$meths)) : [ keys(%$meths) ];
        }

        # First, try the original UNIVERSAL::can()
        my $code;
        if ($method =~ /^SUPER::/) {
            # Superclass WRT caller
            my $caller = caller();
            $code = $$GBL{'can'}->($thing, $caller.'::'.$method);
        } else {
            $code = $$GBL{'can'}->($thing, $method);
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
        foreach my $package (@{$$GBL{'tree'}{'bu'}{$class}}) {
            # Skip self's class if SUPER
            if ($super && $class eq $package) {
                next;
            }

            # Check heritage
            if (exists($$GBL{'heritage'}{$package})) {
                foreach my $pkg (keys(%{$$GBL{'heritage'}{$package}{'cl'}})) {
                    if ($code = $$GBL{'can'}->($pkg, $method)) {
                        return ($code);
                    }
                }
            }

            # Check with the Automethods
            if (my $automethod = $$GBL{'sub'}{'auto'}{$package}) {
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

        # Is it a metadata call?
        if (! $type) {
            return $thing->Object::InsideOut::meta()->get_classes();
        }

        # First, try the original UNIVERSAL::isa()
        if (my $isa = $$GBL{'isa'}->($thing, $type)) {
            return ($isa);
        }

        # Next, check heritage
        foreach my $package (@{$$GBL{'tree'}{'bu'}{ref($thing) || $thing}}) {
            if (exists($$GBL{'heritage'}{$package})) {
                foreach my $pkg (keys(%{$$GBL{'heritage'}{$package}{'cl'}})) {
                    if (my $isa = $$GBL{'isa'}->($pkg, $type)) {
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
my $VERSION = 3.01;
($Object::InsideOut::VERSION == 3.01) or die("Version mismatch\n");
