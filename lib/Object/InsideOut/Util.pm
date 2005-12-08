package Object::InsideOut::Util; {

require 5.006;

use strict;
use warnings;

our $VERSION = 1.19;


### Module Initialization ###

# 1. Install our own 'no-op' version of Internals::SvREADONLY for Perl < 5.8
BEGIN {
    if (! Internals->can('SvREADONLY')) {
        *Internals::SvREADONLY = sub (\$;$) { return; };
    }
}


# 2. Export requested subroutines
sub import
{
    my $class = shift;   # Not used

    # Exportable subroutines
    my %EXPORT_OK;
    @EXPORT_OK{qw(create_object process_args
                  set_data make_shared shared_copy
                  hash_re is_it)} = undef;

    # Handle entries in the import list
    my $caller = caller();
    while (my $sym = shift) {
        if (exists($EXPORT_OK{lc($sym)})) {
            # Export subroutine name
            no strict 'refs';
            *{$caller.'::'.$sym} = \&{lc($sym)};
        } else {
            OIO::Code->die(
                'message' => "Symbol '$sym' is not exported by Object::InsideOut::Util",
                'Info'    => 'Exportable symbols: ' . join(' ', keys(%EXPORT_OK)));
        }
    }
}


### Subroutines ###

# Returns a blessed (optional), readonly (Perl 5.8) anonymous scalar reference
# containing either:
#   the value returned by a user-specified subroutine; or
#   a user-supplied scalar
sub create_object
{
    my ($class, $id) = @_;

    # Create the object from an anonymous scalar reference
    my $obj = \do{ my $scalar; };

    # Set the scalar equal to ...
    if (my $ref_type = ref($id)) {
        if ($ref_type eq 'CODE') {
            # ... the value returned by the user-specified subroutine
            local $SIG{__DIE__} = 'OIO::trap';
            $$obj = $id->($class);
        } else {
            # Complain if something other than code ref
            OIO::Args->die(
                'message' => q/2nd argument to create_object() is not a code ref or scalar/,
                'Usage'   => 'create_object($class, $scalar) or create_object($class, $code_ref, ...)');
        }

    } else {
        # ... the user-supplied scalar
        $$obj = $id;
    }

    # Bless the object into the specified class (optional)
    if ($class) {
        bless($obj, $class);
    }

    # Make the object 'readonly' (Perl 5.8)
    Internals::SvREADONLY($$obj, 1) if ($] >= 5.008003);

    # Done - return the object
    return ($obj);
}


# Extracts specified args from those given
sub process_args
{
    # First arg may optionally be a class name.  Otherwise, use caller().
    my $class = (ref($_[0])) ? caller() : shift;
    my $self  = shift;   # Object begin initialized with args
    my $spec  = shift;   # Hash ref of arg specifiers
    my $args  = shift;   # Hash ref of args

    # Check for correct usage
    if ((ref($spec) ne 'HASH') || (ref($args) ne 'HASH')) {
        OIO::Args->die(
            'message' => q/Last 2 args to process_args() must be hash refs/,
            'Usage'   => q/process_args($object, $spec_hash_ref, $arg_hash_ref) or process_args($class, $object, $spec_hash_ref, $arg_hash_ref)/);
    }

    # Extract/build arg-matching regexs from the specifiers
    my %regex;
    foreach my $key (keys(%{$spec})) {
        my $regex = $spec->{$key};
        # If the value for the key is a hash ref, then the regex may be
        # inside it
        if (ref($regex) eq 'HASH') {
            $regex = hash_re($regex, qr/^RE(?:GEXp?)?$/i);
        }
        # Turn $regex into an actual 'Regexp', if needed
        if ($regex && ref($regex) ne 'Regexp') {
            $regex = qr/^$regex$/;
        }
        # Store it
        $regex{$key} = $regex;
    }

    # Search for specified args
    my %found = ();
    EXTRACT: {
        # Find arguments using regex's
        foreach my $key (keys(%regex)) {
            my $regex = $regex{$key};
            my $value = ($regex) ? hash_re($args, $regex) : $args->{$key};
            if (defined($found{$key})) {
                if (defined($value)) {
                    $found{$key} = $value;
                }
            } else {
                $found{$key} = $value;
            }
        }

        # Check for class-specific argument hash ref
        if (exists($args->{$class})) {
            $args = $args->{$class};
            if (ref($args) ne 'HASH') {
                OIO::Args->die(
                    'caller_level' => 1,
                    'message'      => "Bad class initializer for '$class'",
                    'Usage'        => q/Class initializers must be a hash ref/);
            }
            # Loop back to process class-specific arguments
            redo EXTRACT;
        }
    }

    # Check on what we've found
    CHECK:
    foreach my $key (keys(%{$spec})) {
        my $spec = $spec->{$key};
        # No specs to check
        if (ref($spec) ne 'HASH') {
            # The specifier entry was just 'key => regex'.  If 'key' is not in
            # the args, the we need to remove the 'undef' entry in the found
            # args hash.
            if (! defined($found{$key})) {
                delete($found{$key});
            }
            next CHECK;
        }

        # Handle args not found
        if (! defined($found{$key})) {
            # Complain if mandatory
            if (hash_re($spec, qr/^MANDATORY$/i)) {
                OIO::Args->die(
                    'caller_level' => 1,
                    'message'      => "Missing mandatory initializer '$key' for class '$class'");
            }

            # Assign default value
            $found{$key} = clone(hash_re($spec, qr/^DEF(?:AULTs?)?$/i));

            # If no default, then remove it from the found args hash
            if (! defined($found{$key})) {
                delete($found{$key});
                next CHECK;
            }
        }

        # Check for correct type
        if (defined(my $type = hash_re($spec, qr/^TYPE$/i))) {
            # Custom type checking
            if (ref($type)) {
                if (ref($type) ne 'CODE') {
                    OIO::Code->die(
                        'caller_level' => 1,
                        'message'      => q/Can't validate argument/,
                        'Info'         => "'Type' is not a code ref or string for initializer '$key' for class '$class'");
                }

                my ($ok, @errs);
                local $SIG{__WARN__} = sub { push(@errs, @_); };
                eval { $ok = $type->($found{$key}) };
                if ($@ || @errs) {
                    my ($err) = split(/ at /, $@ || join(" | ", @errs));
                    OIO::Code->die(
                        'caller_level' => 1,
                        'message'      => "Problem with type check routine for initializer '$key' for class '$class",
                        'Error'        => $err);
                }
                if (! $ok) {
                    OIO::Args->die(
                        'caller_level' => 1,
                        'message'      => "Initializer '$key' for class '$class' failed type check: $found{$key}");
                }
            }

            # Is it supposed to be a number
            elsif ($type =~ /^num/i) {
                if (! Scalar::Util::looks_like_number($found{$key})) {
                OIO::Args->die(
                    'caller_level' => 1,
                    'message'      => "Bad value for initializer '$key': $found{$key}",
                    'Usage'        => "Initializer '$key' for class '$class' must be a number");
                }
            }

            # For 'LIST', turn anything not an array ref into an array ref
            elsif ($type =~ /^list$/i) {
                if (ref($found{$key}) ne 'ARRAY') {
                    $found{$key} = [ $found{$key} ];
                }
            }

            # Otherwise, check for a specific class or ref type
            # Exact spelling and case required
            elsif (! is_it($found{$key}, $type)) {
                OIO::Args->die(
                    'caller_level' => 1,
                    'message'      => "Bad value for initializer '$key': $found{$key}",
                    'Usage'        => "Initializer '$key' for class '$class' must be an object or ref of type '$type'");
            }
        }

        # If the destination field is specified, then put it in, and remove it
        # from the found args hash.  If thread-sharing, then make sure the
        # value is thread-shared.
        if (defined(my $field = hash_re($spec, qr/^FIELD$/i))) {
            $self->set($field, delete($found{$key}));
        }
    }

    # Done - return remaining found args
    return (\%found);
}


# Make a thread-shared copy of a complex data structure,
# if it is not already thread-shared
sub make_shared
{
    my $in = $_[0];

    # If not sharing, or if already thread-shared, then just return
    # the input
    if (! $threads::shared::threads_shared ||
        ! defined($in) ||
        threads::shared::_id($in))
    {
        return ($in);
    }

    return (shared_copy($in));
}


# Make a copy of a complex data structure that is thread-shared.
sub shared_copy
{
    # If not thread sharing, then make a 'regular' copy.
    if (! $threads::shared::threads_shared) {
        return (clone(@_));
    }

    # Make copies of array, hash and scalar refs
    my $in = $_[0];
    if (my $ref_type = ref($in)) {
        # Copy an array ref
        if ($ref_type eq 'ARRAY') {
            # Make empty shared array ref
            my $out = &threads::shared::share([]);
            # Recursively copy and add contents
            for my $val (@$in) {
                push(@$out, shared_copy($val));
            }
            return ($out);
        }

        # Copy a hash ref
        if ($ref_type eq 'HASH') {
            # Make empty shared hash ref
            my $out = &threads::shared::share({});
            # Recursively copy and add contents
            foreach my $key (keys(%{$in})) {
                $out->{$key} = shared_copy($in->{$key});
            }
            return ($out);
        }

        # Copy a scalar ref
        if ($ref_type eq 'SCALAR') {
            return (threads::shared::share($in));
        }
    }

    # Just return anything else
    # NOTE: This will generate an error if we're thread-sharing,
    #       and $in is not an ordinary scalar.
    return ($in);
}


# Make a copy of a complex data structure.
sub clone
{
    # Make copies of array, hash and scalar refs
    my $in = $_[0];
    if (my $ref_type = ref($in)) {
        # Copy an array ref
        if ($ref_type eq 'ARRAY') {
            # Make empty shared array ref
            my $out = [];
            # Recursively copy and add contents
            for my $val (@$in) {
                push(@$out, clone($val));
            }
            return ($out);
        }

        # Copy a hash ref
        if ($ref_type eq 'HASH') {
            # Make empty shared hash ref
            my $out = {};
            # Recursively copy and add contents
            foreach my $key (keys(%{$in})) {
                $out->{$key} = clone($in->{$key});
            }
            return ($out);
        }

        # Copy a scalar ref
        if ($ref_type eq 'SCALAR') {
            my $out = \do{ my $scalar; };
            $$out = $$in;
            return ($out);
        }
    }

    # Just return anything else
    return ($in);
}


# Access hash value using regex
sub hash_re
{
    my $hash = $_[0];   # Hash ref to search through
    my $re   = $_[1];   # Regex to match keys against

    for (keys(%{$hash})) {
        if (/$re/) {
            return ($hash->{$_});
        }
    }
    return;
}


# Checks if a scalar is a specified type
sub is_it
{
    my ($thing, $what) = @_;

    return ((Scalar::Util::blessed($thing))
                ? $thing->isa($what)
                : (ref($thing) eq $what));
}

}  # End of package's lexical scope

1;

__END__

