package Object::InsideOut::Util; {

require 5.006;

use strict;
use warnings;

our $VERSION = '0.01.00';


### Module Initialization ###

# 1. Install our own 'no-op' version of Internals::SvREADONLY for Perl < 5.8
BEGIN {
    if (! Internals->can('SvREADONLY')) {
        *Internals::SvREADONLY = sub (\[$%@];$) { return; };
    }
}


# 2. Export requested subroutines
sub import
{
    my $class = shift;   # Not used

    # Exportable subroutines
    my %EXPORT_OK;
    @EXPORT_OK{qw(create_object process_args
                  shared_copy make_shared
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
#   the address of the reference;
#   the value returned by a user-specified subroutine; or
#   a user-supplied scalar
sub create_object
{
    my ($class, $id, @args) = @_;

    # Create the object from an anonymous scalar reference
    my $obj = \(my $scalar);

    # Set the scalar equal to ...
    if (! defined($id)) {
        # ... the address of the reference
        $$obj = Scalar::Util::refaddr($obj);

    } elsif (my $ref_type = ref($id)) {
        if ($ref_type eq 'CODE') {
            # ... the value returned by the user-specified subroutine
            $$obj = $id->(@args);
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
    Internals::SvREADONLY($$obj, 1);

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
    while (my ($key, $regex) = each(%{$spec})) {
        # If the value for the key is a hash ref, then the regex may be
        # inside it
        if (ref($regex) eq 'HASH') {
            $regex = hash_re($regex, qr/^RE(?:GEXp?)?$/i);
        }
        # If no regex, then just use the key itself
        if (! $regex) {
            $regex = $key;
        }
        # Turn $regex into an actual 'Regexp', if needed
        if (ref($regex) ne 'Regexp') {
            $regex = qr/^$regex$/;
        }
        # Store it
        $regex{$key} = $regex;
    }

    # Search for specified args
    my %found = ();
    EXTRACT: {
        # Find arguments using regex's
        while (my ($key, $regex) = each(%regex)) {
            $found{$key} = hash_re($args, $regex);
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
    while (my ($key, $spec) = each(%{$spec})) {
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
            $found{$key} = hash_re($spec, qr/^DEF(?:AULTs?)?$/i);

            # If no default, then remove it from the found args hash
            if (! defined($found{$key})) {
                delete($found{$key});
                next CHECK;
            }
        }

        # Check for correct type
        if (defined(my $type = hash_re($spec, qr/^TYPE$/i))) {
            # Is it supposed to be a number
            if ($type =~ /^num/i) {
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
            if ($threads::shared::threads_shared &&
                threads::shared::_id($field))
            {
                lock($field);
                $field->{$$self} = make_shared(delete($found{$key}));
            } else {
                $field->{$$self} = delete($found{$key});
            }
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
        threads::shared::_id($in))
    {
        return ($in);
    }

    return (shared_copy($in));
}


# Make a copy of a complex data structure that is thread-shared.
# If not thread sharing, then make a 'regular' copy.
sub shared_copy
{
    my $in = $_[0];

    # Make copies of array, hash and scalar refs
    if (my $ref_type = ref($in)) {
        # Copy an array ref
        if ($ref_type eq 'ARRAY') {
            # Make empty shared array ref
            my $out = ($threads::shared::threads_shared)
                            ? &threads::shared::share([])
                            : [];
            # Recursively copy and add contents
            for my $val (@$in) {
                push(@$out, shared_copy($val));
            }
            return ($out);
        }

        # Copy a hash ref
        if ($ref_type eq 'HASH') {
            # Make empty shared hash ref
            my $out = ($threads::shared::threads_shared)
                            ? &threads::shared::share({})
                            : {};
            # Recursively copy and add contents
            while (my ($key, $val) = each(%$in)) {
                $out->{$key} = shared_copy($val);
            }
            return ($out);
        }

        # Copy a scalar ref
        if ($ref_type eq 'SCALAR') {
            if ($threads::shared::threads_shared) {
                return (threads::shared::share($in));
            }
            # If not sharing, then make a copy of the scalar ref
            my $out = \(my $scalar);
            $$out = $$in;
            return ($out);
        }
    }

    # Just return anything else
    # NOTE: This will generate an error if we're thread-sharing,
    #       and $in is not an ordinary scalar.
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

=head1 NAME

Object::InsideOut::Util - Utilities for inside-out objects

=head1 SYNOPSIS

    ### In Class ###

    use Math::Random::MT::Auto::Util;

    sub new
    {
        ...

        my %args = process_args( {
                                    'PARAMS' => '/^(?:param|parm)s?$/i',
                                    'OPTION' => '/^(?:option|opt)$/i',
                                    'TYPE'   => '/^type$/i'
                                 },
                                 @_ );
        ...

        return ($self);
    }

    ### In Application ###

    my %initializers = (
          'Option' => 'filter',
          'Type'   => 'integer',
          'Math::Random::MT::Auto' => { 'Src' => 'dev_random' },
    );

    my $obj = My::Random->new(\%initializers,
                              'parms' => [ 4, 12 ]);

    ### Sample Class Code ###

    package My::Class;

    use strict;
    use warnings;
    use Scalar::Util qw(weaken);
    use Object::InsideOut::Util;

    # Object attributes hashes
    my %options_for;
    my %flags_for;
    my %tags_for;

    # Maintains weak references to objects for thread cloning
    my %REGISTRY;

    sub new
    {
        my $thing = shift;
        my $class = ref($thing) || $thing;

        ### Extract arguments needed by this class

        my %args = process_args( {
                                  'OPTION' => '/^(?:option|opt)s?$/i',
                                  'FLAG'   => '/^flag$/i',
                                  'TAG'    => '/^tags?$/i'
                                 },
                                 @_ );

        ### Validate arguments and/or add defaults
        ...

        ### Create object

        # If this is a base class, then create a new object
        my $self = bless(create_ref(), $class);
        # Make it non-modifiable
        Internals::SvREADONLY($$self, 1);

        # If this is a subclass, then obtain new object from parent class
        # my $self = $class->SUPER::new(@_);

        # Save weakened reference to object for thread cloning
        weaken($REGISTRY{$$self} = $self);

        ### Initialize object
        $options_for{$$self} = $args{'OPTION'};
        $flags_for{$$self}   = $args{'FLAG'};
        $tags_for{$$self}    = $args{'TAG'};

        ### Done - return object
        return ($self);
    }

    ### Sample Application Code ###

    #!/usr/bin/perl

    use strict;
    use warnings;
    use My::Class;

    # Create an 'empty' subclass
    @My::Class::Sub::ISA = 'My::Class';

    # Set up common and class-specific initializers
    my %initializers = (
          'opts' => [ 'VARIABLE', 'INTEGER' ],
          'My::Class'      => {
                                  'Flag'   => 'VOLATILE'
                                  'Remark' => 'This will be ignored'
                              },
          'My::Class::Sub' => {
                                  'Flag'    => 'PERMANENT'
                                  'Comment' => 'Also ignored'
                              },
    );

    # Create an object from the base class
    my $base_obj = My::Class->new(\%initializers,
                                  'tag' => 'Base');

    # Create an object from the subclass
    my $sub_obj = My::Class::Sub->new(\%initializers,
                                      'tags => [ 'Base', 'Subclass' ]);

=head1 DESCRIPTION

This module provides utilities that support the inside-out object model.

=over

=item create_object

  my $ref = create_object($class);
  my $ref = create_object($class, $scalar);
  my $ref = create_object($class, $code_ref, ...);

This subroutine returns an object that consists of a reference to an anonymous
scalar that is blessed into the specified class.

The scalar is populated with a unique ID that can be used to reference the
object's attributes (this gives a preformance improvement over other ID
schemes).  For example,

  my $obj = create_object($class);
  $attribute{$$obj} = $value;

When called with just the $class argument, the referenced scalar is populated
with the address of the reference.

When called with an additional scalar argument, the referenced scalar will be
populated with the argument.

Finally, you can supply your own code for setting the object ID.  In this
case, provide a reference to the desired subroutine (or specify an anonymous
subroutine), followed by any arguments that it might need.  For example,

  my $obj = create_object($class, \&my_uniq_id, $arg1, $arg2);

If $class is undef, then an unblessed scalar reference is returned.

For safety, the value of the scalar is set to 'readonly'.

This subroutine will normally only be used in the object constructor of a base
class.

=item process_args

    my %args = process_args( { 'OPTION' => 'REGEX', ... }, @_ );

This subroutine provides a powerful and flexible mechanism for subclass
constructors to accept arguments from application code, and to extract the
arguments they need.  It processes the argument list sent to the constructor,
extracting arguments based on regular expressions, and returns a hash of the
matches.

The arguments are presented to the constructor in any combination of
C<key =E<gt> value> pairs and/or hash refs.  These are combined by
C<process_args> into a single hash from which arguments are extracted, and
returned to the constructor.

Additionally, hash nesting is supported for providing class-specific
arguments.  For this feature, a key that is the name of a class is paired with
a hash reference containing arguments that are meant for that class's
constructor.

    my $obj = My::Class::Sub::Whatever->new(
                    'param'         => 'value',
                    'My::Class'     => {
                                            'param' => 'item',
                                       },
                    'My::Class:Sub' => {
                                            'param' => 'property',
                                       },
              );

In the above, class C<My::Class::Sub::Whatever> will get C<'param' =E<gt>
'value'>, C<My::Class::Sub> will get C<'param' =E<gt> 'property'>, and
C<My::Class> will get C<'param' =E<gt> 'item'>.

The first argument to C<process_args> is a hash ref containing specifications
for the arguments to be extracted.  The keys in this hash will be the keys
in the returned hash for any extracted arguments.  The values are regular
expressions that are used to match the incoming argument keys.  If only an
exact match is desired, then the value for the key should be set to C<undef>.

'param' => undef   doesn't work

REGEX => qr/---/

FIELD => \%field_hash

MANDATORY => 1

DEFAULT => ...

TYPE => NUMBER
        LIST (i.e., array ref or single value which is moved into an array ref)
        ref(x)
                SCALAR
                ARRAY
                HASH
                CODE
                REF
                GLOB
                LVALUE
                Regexp
                'class::name'

=back

=head1 DIAGNOSTICS

'key' => undef

=over

=item * Usage: create_ref() | create_ref($scalar) | create_ref($code_ref, ...)

You called C<create_ref> with a bad argument.

=item * Usage: process_args({ ARG=>\'REGEX\', ... }, @_)

Your call to C<process_args> did not have a hash ref as its first argument.

=item * Bad initializer: XXX ref not allowed. (Must be 'key=>val' pair or hash ref.)

=item * Bad initializer: Missing value for key 'XXX'. (Must be 'key=>val' pair or hash ref.)

=item * Class initializer for 'XXX' must be a hash ref


=item * Cannot share subs yet

Doing thread sharing and tried to pass a code ref to srand()

=item * Invalid value for shared scalar


=back

=head1 BUGS AND LIMITATIONS

For Perl < 5.8, this module exports a version of C<Internals::SvREADONLY> that
is a I<no-op>.

There are no known bugs in this module.

Please submit any bugs, problems, suggestions, patches, etc. to:
L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Math-Random-MT-Auto>

=head1 SEE ALSO

L<Object::InsideOut>

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT 1979 DOT usna DOT comE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2005 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
