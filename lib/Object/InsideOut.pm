package Object::InsideOut; {

require 5.006;

use strict;
use warnings;

our $VERSION = 1.45;

use Object::InsideOut::Exception 1.45;
use Object::InsideOut::Util 1.45 ();

use B;

use Scalar::Util 1.10;
# Verify we have 'weaken'
{
    no warnings 'void';
    BEGIN {
        if (! Scalar::Util->can('weaken')) {
            OIO->Trace(0);
            OIO::Code->die(
                'message' => q/Cannot use 'pure perl' version of Scalar::Util - 'weaken' missing/,
                'Info'    => 'Upgrade/reinstall your version of Scalar::Util');
        }
    }
}


# Flag for running package initialization routine
my $DO_INIT = 1;

# Cached value of original ->isa() method
my $UNIV_ISA = \&UNIVERSAL::isa;

# ID of currently executing thread
my $THREAD_ID = 0;

# Contains flags as to whether or not a class is sharing objects between
# threads
my %IS_SHARING;


### Class Tree Building (via 'import()') ###

# Cache of class trees
my (%TREE_TOP_DOWN, %TREE_BOTTOM_UP);

# Foreign class inheritance information
my %HERITAGE;


# Doesn't export anything - just builds class trees and stores sharing flags
sub import
{
    my $self = shift;      # Ourself (i.e., 'Object::InsideOut')
    if (Scalar::Util::blessed($self)) {
        OIO::Method->die('message' => q/'import' called as an object method/);
    }

    # Invoked via inheritance - ignore
    if ($self ne __PACKAGE__) {
        if (Exporter->can('import')) {
            my $lvl = $Exporter::ExportLevel;
            $Exporter::ExportLevel = (caller() eq __PACKAGE__) ? 3 : 1;
            $self->Exporter::import(@_);
            $Exporter::ExportLevel = $lvl;
        }
        return;
    }

    my $class = caller();   # The class that is using us
    if (! $class || $class eq 'main') {
        OIO::Code->die(
            'message' => q/'import' invoked from 'main'/,
            'Info'    => "Can't use 'use Object::InsideOut;' or 'import Object::InsideOut;' inside application code");
    }

    no strict 'refs';

    # Check for class's global sharing flag
    # (normally set in the app's main code)
    if (defined(${$class.'::shared'})) {
        set_sharing($class, ${$class.'::shared'}, (caller())[1..2]);
    }

    # Check for class's global 'storable' flag
    # (normally set in the app's main code)
    {
        no warnings 'once';
        if (${$class.'::storable'}) {
            push(@_, 'Storable');
        }
    }

    # Import packages and handle :SHARED flag
    my @packages;
    while (my $pkg = shift) {
        next if (! $pkg);    # Ignore empty strings and such

        # Handle thread object sharing flag
        if ($pkg =~ /^:(NOT?_?|!)?SHAR/i) {
            my $sharing = (defined($1)) ? 0 : 1;
            set_sharing($class, $sharing, (caller())[1..2]);
            next;
        }

        # Load the package, if needed
        if (! $class->$UNIV_ISA($pkg)) {
            # If no package symbols, then load it
            if (! grep { $_ !~ /::$/ } keys(%{$pkg.'::'})) {
                eval "require $pkg";
                if ($@) {
                    OIO::Code->die(
                        'message' => "Failure loading package '$pkg'",
                        'Error'   => $@);
                }
                # Empty packages make no sense
                if (! grep { $_ !~ /::$/ } keys(%{$pkg.'::'})) {
                    OIO::Code->die('message' => "Package '$pkg' is empty");
                }
            }

            # Add to package list
            push(@packages, $pkg);
        }

        # Import the package, if needed
        if (ref($_[0])) {
            my $imports = shift;
            if (ref($imports) ne 'ARRAY') {
                OIO::Code->die('message' => "Arguments to '$pkg' must be contained within an array reference");
            }
            eval { $pkg->import(@{$imports}); };
            if ($@) {
                OIO::Code->die(
                    'message' => "Failure running 'import' on package '$pkg'",
                    'Error'   => $@);
            }
        }
    }

    # Create class tree
    my @tree;
    my %seen;   # Used to prevent duplicate entries in @tree
    my $need_oio = 1;
    foreach my $parent (@packages) {
        if (exists($TREE_TOP_DOWN{$parent})) {
            # Inherit from Object::InsideOut class
            foreach my $ancestor (@{$TREE_TOP_DOWN{$parent}}) {
                if (! exists($seen{$ancestor})) {
                    push(@tree, $ancestor);
                    $seen{$ancestor} = undef;
                }
            }
            push(@{$class.'::ISA'}, $parent);
            $need_oio = 0;

        } else { ### Inherit from foreign class
            # Get inheritance 'classes' hash
            if (! exists($HERITAGE{$class})) {
                create_heritage($class);
            }
            my $classes = $HERITAGE{$class}[1];

            # Add parent to inherited classes
            $classes->{$parent} = undef;
        }
    }

    # Add Object::InsideOut to class's @ISA array, if needed
    if ($need_oio) {
        push(@{$class.'::ISA'}, $self);
    }

    # Add calling class to tree
    if (! exists($seen{$class})) {
        push(@tree, $class);
    }

    # Save the trees
    $TREE_TOP_DOWN{$class} = \@tree;
    @{$TREE_BOTTOM_UP{$class}} = reverse(@tree);
}


### Attribute Support ###

# Maintain references to all object field arrays/hashes by package for easy
# manipulation of field data during global object actions (e.g., cloning,
# destruction).  Object field hashes are marked with an attribute called
# 'Field'.
my (%NEW_FIELDS, %FIELDS);

# Fields that require deep cloning
my %DEEP_CLONE;

# Fields that store weakened refs
my %WEAK;

# Field information for the dump() method
my %DUMP_FIELDS;

# Packages with :InitArgs that need to be processed for dump() field info
my @DUMP_INITARGS;

# Allow a single object ID specifier subroutine per class tree.  The
# subroutine ref provided will return the object ID to be used for the object
# that is created by this package.  The ID subroutine is marked with an
# attribute called 'ID', and is :HIDDEN during initialization by default.
my %ID_SUBS;

# Allow a single object initialization hash per class.  The data in these
# hashes is used to initialize newly create objects. The initialization hash
# is marked with an attribute called 'InitArgs'.
my %INIT_ARGS;

# Allow a single initialization subroutine per class that is called as part of
# initializing newly created objects.  The initialization subroutine is marked
# with an attribute called 'Init', and is :HIDDEN during initialization by
# default.
my %INITORS;

# Allow a single pre-initialization subroutine per class that is called as
# part of initializing newly created objects.  The pre-initialization
# subroutine is marked with an attribute called 'PreInit', and is :HIDDEN
# during initialization by default.
my %PREINITORS;

# Allow a single data replication subroutine per class that is called when
# objects are cloned.  The data replication subroutine is marked with an
# attribute called 'Replicate', and is :HIDDEN during initialization by
# default.
my %REPLICATORS;

# Allow a single data destruction subroutine per class that is called when
# objects are destroyed.  The data destruction subroutine is marked with an
# attribute called 'Destroy', and is :HIDDEN during initialization by
# default.
my %DESTROYERS;

# Allow a single 'autoload' subroutine per class that is called when an object
# method is not found.  The automethods subroutine is marked with an
# attribute called 'Automethod', and is :HIDDEN during initialization by
# default.
my %AUTOMETHODS;

# Methods that support 'cumulativity' from the top of the class tree
# downwards, and from the bottom up.  These cumulative methods are marked with
# the attributes 'Cumulative' and 'Cumulative(bottom up)', respectively.
my (%CUMULATIVE, %ANTICUMULATIVE);

# Methods that support 'chaining' from the top of the class tree downwards,
# and the bottom up. These chained methods are marked with an attribute called
# 'Chained' and 'Chained(bottom up)', respectively.
my (%CHAINED, %ANTICHAINED);

# Methods that support object serialization.  These are marked with the
# attribute 'Dumper' and 'Pumper', respectively.
my (%DUMPERS, %PUMPERS);

# Restricted methods are only callable from within the class hierarchy, and
# private methods are only callable from within the class itself.  They are
# are marked with an attribute called 'Restricted' and 'Private', respectively.
my (%RESTRICTED, %PRIVATE);

# Methods that are made uncallable after initialization.  They are marked with
# an attribute called 'HIDDEN'.
my %HIDDEN;

# Methods that are support overloading capabilities for objects.
my %OVERLOAD;

# These are the attributes for designating 'overload' methods.
my @OVERLOAD_ATTRS = qw(STRINGIFY NUMERIFY BOOLIFY
                        ARRAYIFY HASHIFY GLOBIFY CODIFY);


# This subroutine handles attributes on hashes as part of this package.
# See 'perldoc attributes' for details.
sub MODIFY_HASH_ATTRIBUTES
{
    my ($pkg, $hash, @attrs) = @_;

    my @unused_attrs;   # List of any unhandled attributes

    # Process attributes
    foreach my $attr (@attrs) {
        # Declaration for object field hash
        if ($attr =~ /^Field/i) {
            # Save save hash ref and accessor declarations
            # Accessors will be build during initialization
            my ($decl) = $attr =~ /^Fields?\s*(?:[(]\s*(.*)\s*[)])/i;
            push(@{$NEW_FIELDS{$pkg}}, [ $hash, $decl ]);
            $DO_INIT = 1;   # Flag that initialization is required
        }

        # Declaration for object initializer hash
        elsif ($attr =~ /^InitArgs?$/i) {
            $INIT_ARGS{$pkg} = $hash;
            push(@DUMP_INITARGS, $pkg);
        }

        # Handle ':shared' attribute associated with threads::shared
        elsif ($attr eq 'shared') {
            if ($threads::shared::threads_shared) {
                threads::shared::share($hash);
            }
        }

        # Unhandled
        else {
            push(@unused_attrs, $attr);
        }
    }

    # If using Attribute::Handlers, send it any unused attributes
    if (@unused_attrs &&
        Attribute::Handlers::UNIVERSAL->can('MODIFY_HASH_ATTRIBUTES'))
    {
        return (Attribute::Handlers::UNIVERSAL::MODIFY_HASH_ATTRIBUTES($pkg, $hash, @unused_attrs));
    }

    # Return any unused attributes
    return (@unused_attrs);
}


# This subroutine handles attributes on arrays as part of this package.
# See 'perldoc attributes' for details.
sub MODIFY_ARRAY_ATTRIBUTES
{
    my ($pkg, $array, @attrs) = @_;

    my @unused_attrs;   # List of any unhandled attributes

    # Process attributes
    foreach my $attr (@attrs) {
        # Declaration for object field array
        if ($attr =~ /^Field/i) {
            # Save save array ref and accessor declarations
            # Accessors will be build during initialization
            my ($decl) = $attr =~ /^Fields?\s*(?:[(]\s*(.*)\s*[)])/i;
            push(@{$NEW_FIELDS{$pkg}}, [ $array, $decl ]);
            $DO_INIT = 1;   # Flag that initialization is required
        }

        # Handle ':shared' attribute associated with threads::shared
        elsif ($attr eq 'shared') {
            if ($threads::shared::threads_shared) {
                threads::shared::share($array);
            }
        }

        # Unhandled
        else {
            push(@unused_attrs, $attr);
        }
    }

    # If using Attribute::Handlers, send it any unused attributes
    if (@unused_attrs &&
        Attribute::Handlers::UNIVERSAL->can('MODIFY_ARRAY_ATTRIBUTES'))
    {
        return (Attribute::Handlers::UNIVERSAL::MODIFY_ARRAY_ATTRIBUTES($pkg, $array, @unused_attrs));
    }

    # Return any unused attributes
    return (@unused_attrs);
}


# Handles subroutine attributes supported by this package.
# See 'perldoc attributes' for details.
sub MODIFY_CODE_ATTRIBUTES
{
    my ($pkg, $code, @attrs) = @_;

    # Save caller info with code ref for error reporting purposes
    my $info = [ $code, [ $pkg, (caller(2))[1,2] ] ];

    my @unused_attrs;   # List of any unhandled attributes

    # Save the code refs in the appropriate hashes
    while (my $attribute = shift(@attrs)) {
        my ($attr, $arg) = $attribute =~ /(\w+)(?:[(]\s*(.*)\s*[)])?/;
        $attr = uc($attr);
        # Attribute may be followed by 'PUBLIC', 'PRIVATE' or 'RESTRICED'
        # Default to 'HIDDEN' if none.
        $arg = ($arg) ? uc($arg) : 'HIDDEN';

        if ($attr eq 'ID') {
            $ID_SUBS{$pkg} = [ $code, @{$$info[1]} ];
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr eq 'PREINIT') {
            $PREINITORS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr eq 'INIT') {
            $INITORS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^REPL(?:ICATE)?$/) {
            $REPLICATORS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^DEST(?:ROY)?$/) {
            $DESTROYERS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^AUTO(?:METHOD)?$/) {
            $AUTOMETHODS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr =~ /^CUM(?:ULATIVE)?$/) {
            if ($arg =~ /BOTTOM\s+UP/) {
                push(@{$ANTICUMULATIVE{$pkg}}, $info);
            } else {
                push(@{$CUMULATIVE{$pkg}}, $info);
            }
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr =~ /^CHAIN(?:ED)?$/) {
            if ($arg =~ /BOTTOM\s+UP/) {
                push(@{$ANTICHAINED{$pkg}}, $info);
            } else {
                push(@{$CHAINED{$pkg}}, $info);
            }
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr =~ /^DUMP(?:ER)?$/) {
            $DUMPERS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^PUMP(?:ER)?$/) {
            $PUMPERS{$pkg} = $code;
            # Process attribute 'arg' as an attribute
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^RESTRICT(?:ED)?$/) {
            push(@{$RESTRICTED{$pkg}}, $info);
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr =~ /^PRIV(?:ATE)?$/) {
            push(@{$PRIVATE{$pkg}}, $info);
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr eq 'HIDDEN') {
            push(@{$HIDDEN{$pkg}}, $info);
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr eq 'SCALARIFY') {
            OIO::Attribute->die(
                'message' => q/:SCALARIFY not allowed/,
                'Info'    => q/The scalar of an object is its object ID, and can't be redefined/,
                'ignore_package' => 'attributes');

        } elsif (my ($ify_attr) = grep { $_ eq $attr } @OVERLOAD_ATTRS) {
            # Overload (-ify) attributes
            push(@{$OVERLOAD{$pkg}}, [$ify_attr, @{$info} ]);
            $DO_INIT = 1;   # Flag that initialization is required

        } elsif ($attr !~ /^PUB(LIC)?$/) {   # PUBLIC is ignored
            # Not handled
            push(@unused_attrs, $attribute);
        }
    }

    # If using Attribute::Handlers, send it any unused attributes
    if (@unused_attrs &&
        Attribute::Handlers::UNIVERSAL->can('MODIFY_CODE_ATTRIBUTES'))
    {
        return (Attribute::Handlers::UNIVERSAL::MODIFY_CODE_ATTRIBUTES($pkg, $code, @unused_attrs));
    }

    # Return any unused attributes
    return (@unused_attrs);
}


### Array-based Object Support ###

# Object ID counters - one for each class tree possibly per thread
my %ID_COUNTERS;
# Reclaimed object IDs
my %RECLAIMED_IDS;

if ($threads::shared::threads_shared) {
    threads::shared::share(%ID_COUNTERS);
    threads::shared::share(%RECLAIMED_IDS);
}

# Must have a least one key due to 'Perl bug workaround' below
$RECLAIMED_IDS{'::'} = undef;

# Supplies an ID for an object being created in a class tree
# and reclaims IDs from destroyed objects
sub _ID
{
    my ($class, $id) = @_;            # The object's class and id
    my $tree = $ID_SUBS{$class}[1];   # The object's class tree

    # If class is sharing, then all ID tracking is done as though in thread 0,
    # else tracking is done per thread
    my $thread_id = (is_sharing($class)) ? 0 : $THREAD_ID;

    # Save deleted IDs for later reuse
    if ($id) {
        local $SIG{__WARN__} = sub { };   # Suppress spurious msg
        if (keys(%RECLAIMED_IDS)) {       # Perl bug workaround
            if (! exists($RECLAIMED_IDS{$tree})) {
                $RECLAIMED_IDS{$tree} = ($threads::shared::threads_shared)
                                            ? &threads::shared::share([])
                                            : [];
            }
            if (! exists($RECLAIMED_IDS{$tree}[$thread_id])) {
                $RECLAIMED_IDS{$tree}[$thread_id] = ($threads::shared::threads_shared)
                                                        ? &threads::shared::share([])
                                                        : [];

            } elsif (grep { $_ == $id } @{$RECLAIMED_IDS{$tree}[$thread_id]}) {
                print(STDERR "ERROR: Duplicate reclaimed object ID ($id) in class tree for $tree in thread $thread_id\n");
                return;
            }
            push(@{$RECLAIMED_IDS{$tree}[$thread_id]}, $id);
        }
        return;
    }

    # Use a reclaimed ID if available
    if (exists($RECLAIMED_IDS{$tree}) &&
        exists($RECLAIMED_IDS{$tree}[$thread_id]) &&
        @{$RECLAIMED_IDS{$tree}[$thread_id]})
    {
        return (shift(@{$RECLAIMED_IDS{$tree}[$thread_id]}));
    }

    # Return the next ID
    if (! exists($ID_COUNTERS{$tree})) {
        $ID_COUNTERS{$tree} = ($threads::shared::threads_shared)
                                    ? &threads::shared::share([])
                                    : [];
    }
    return (++$ID_COUNTERS{$tree}[$thread_id]);
}


### Initialization Handling ###

# Finds a subroutine's name from its code ref
sub sub_name :Private
{
    my ($ref, $attr, $location) = @_;

    my $name;
    eval { $name = B::svref_2object($ref)->GV()->NAME(); };
    if ($@) {
        OIO::Attribute->die(
            'location' => $location,
            'message'  => "Failure finding name for subroutine with $attr attribute",
            'Error'    => $@);

    } elsif ($name eq '__ANON__') {
        OIO::Attribute->die(
            'location' => $location,
            'message'  => q/Subroutine name not found/,
            'Info'     => "Can't use anonymous subroutine for $attr attribute");
    }

    return ($name);   # Found
}


# Perform much of the 'magic' for this module
sub initialize :Private
{
    $DO_INIT = 0;   # Clear initialization flag

    no warnings 'redefine';
    no strict 'refs';

    my $reapply;
    do {
        $reapply = 0;

        # Propagate ID subs through the class hierarchies
        foreach my $class (keys(%TREE_TOP_DOWN)) {
            # Find ID sub for this class somewhere in its hierarchy
            my $id_sub_pkg;
            foreach my $pkg (@{$TREE_TOP_DOWN{$class}}) {
                if ($ID_SUBS{$pkg}) {
                    if ($id_sub_pkg) {
                        # Verify that all the ID subs in heirarchy are the same
                        if (($ID_SUBS{$pkg}[0] != $ID_SUBS{$id_sub_pkg}[0]) ||
                            ($ID_SUBS{$pkg}[1] ne $ID_SUBS{$id_sub_pkg}[1]))
                        {
                            my ($p,    $file,  $line)  = @{$ID_SUBS{$pkg}}[1..3];
                            my ($pkg2, $file2, $line2) = @{$ID_SUBS{$id_sub_pkg}}[1..3];
                            OIO::Attribute->die(
                                'message' => "Multiple :ID subs defined within hierarchy for '$class'",
                                'Info'    => ":ID subs in class '$pkg' (file '$file', line $line), and class '$pkg2' (file '$file2' line $line2)");
                        }
                    } else {
                        $id_sub_pkg = $pkg;
                    }
                }
            }

            # If ID sub found, propagate it through the class hierarchy
            if ($id_sub_pkg) {
                foreach my $pkg (@{$TREE_TOP_DOWN{$class}}) {
                    if (! exists($ID_SUBS{$pkg})) {
                        $ID_SUBS{$pkg} = $ID_SUBS{$id_sub_pkg};
                        $reapply = 1;
                    }
                }
            }
        }

        # Check for any classes without ID subs
        if (! $reapply) {
            foreach my $class (keys(%TREE_TOP_DOWN)) {
                if (! exists($ID_SUBS{$class})) {
                    # Default to internal ID sub and propagate it
                    $ID_SUBS{$class} = [ \&_ID, $class, '-', '-' ];
                    $reapply = 1;
                    last;
                }
            }
        }
    } while ($reapply);


    # If needed, process any thread object sharing flags
    if (%IS_SHARING && $threads::shared::threads_shared) {
        foreach my $flag_class (keys(%IS_SHARING)) {
            # Find the class in any class tree
            foreach my $tree (values(%TREE_TOP_DOWN)) {
                if (grep /^$flag_class$/, @$tree) {
                    # Check each class in the tree
                    foreach my $class (@$tree) {
                        if (exists($IS_SHARING{$class})) {
                            # Check for sharing conflicts
                            if ($IS_SHARING{$class}[0] != $IS_SHARING{$flag_class}[0]) {
                                my ($pkg1, @loc, $pkg2, $file, $line);
                                if ($IS_SHARING{$flag_class}[0]) {
                                    $pkg1 = $flag_class;
                                    @loc  = ($flag_class, (@{$IS_SHARING{$flag_class}})[1..2]);
                                    $pkg2 = $class;
                                    ($file, $line) = (@{$IS_SHARING{$class}})[1..2];
                                } else {
                                    $pkg1 = $class;
                                    @loc  = ($class, (@{$IS_SHARING{$class}})[1..2]);
                                    $pkg2 = $flag_class;
                                    ($file, $line) = (@{$IS_SHARING{$flag_class}})[1..2];
                                }
                                OIO::Code->die(
                                    'location' => \@loc,
                                    'message'  => "Can't combine thread-sharing classes ($pkg1) with non-sharing classes ($pkg2) in the same class tree",
                                    'Info'     => "Class '$pkg1' was declared as sharing (file '$loc[1]' line $loc[2]), but class '$pkg2' was declared as non-sharing (file '$file' line $line)");
                            }
                        } else {
                            # Add the sharing flag to this class
                            $IS_SHARING{$class} = $IS_SHARING{$flag_class};
                        }
                    }
                }
            }
        }
    }


    # Process :FIELD declarations
    process_fields();


    # Implement UNIVERSAL::can/isa with :AutoMethods
    if (%AUTOMETHODS) {
        install_UNIVERSAL();
    }


    # Implement cumulative methods
    if (%CUMULATIVE || %ANTICUMULATIVE) {
        generate_CUMULATIVE(\%CUMULATIVE,    \%ANTICUMULATIVE,
                            \%TREE_TOP_DOWN, \%TREE_BOTTOM_UP, $UNIV_ISA);
        undef(%CUMULATIVE);      # No longer needed
        undef(%ANTICUMULATIVE);
    }


    # Implement chained methods
    if (%CHAINED || %ANTICHAINED) {
        generate_CHAINED(\%CHAINED,       \%ANTICHAINED,
                         \%TREE_TOP_DOWN, \%TREE_BOTTOM_UP, $UNIV_ISA);
        undef(%CHAINED);      # No longer needed
        undef(%ANTICHAINED);
    }


    # Implement overload (-ify) operators
    if (%OVERLOAD) {
        generate_OVERLOAD(\%OVERLOAD, \%TREE_TOP_DOWN);
        undef(%OVERLOAD);   # No longer needed
    }


    # Implement restricted methods - only callable within hierarchy
    foreach my $package (keys(%RESTRICTED)) {
        foreach my $info (@{$RESTRICTED{$package}}) {
            my ($code, $location) = @{$info};
            my $name = sub_name($code, ':RESTRICTED', $location);
            *{$package.'::'.$name} = create_RESTRICTED($package, $name, $code);
        }
    }
    undef(%RESTRICTED);   # No longer needed


    # Implement private methods - only callable from class itself
    foreach my $package (keys(%PRIVATE)) {
        foreach my $info (@{$PRIVATE{$package}}) {
            my ($code, $location) = @{$info};
            my $name = sub_name($code, ':PRIVATE', $location);
            *{$package.'::'.$name} = create_PRIVATE($package, $name, $code);
        }
    }
    undef(%PRIVATE);   # No longer needed


    # Implement hidden methods - no longer callable by name
    foreach my $package (keys(%HIDDEN)) {
        foreach my $info (@{$HIDDEN{$package}}) {
            my ($code, $location) = @{$info};
            my $name = sub_name($code, ':HIDDEN', $location);
            create_HIDDEN($package, $name);
        }
    }
    undef(%HIDDEN);   # No longer needed


    # Export methods
    export_methods();
}


# Process :FIELD declarations for shared hashes/arrays and accessors
sub process_fields :Private
{
    foreach my $pkg (keys(%NEW_FIELDS)) {
        foreach my $item (@{$NEW_FIELDS{$pkg}}) {
            my ($fld, $decl) = @{$item};

            # Share the field, if applicable
            if (is_sharing($pkg)) {
                # Preserve any contents
                my $contents = Object::InsideOut::Util::shared_clone($fld);

                # Share the field
                threads::shared::share($fld);

                # Restore contents
                if ($contents) {
                    if (ref($fld) eq 'ARRAY') {
                        @{$fld} = @{$contents};
                    } else {
                        %{$fld} = %{$contents};
                    }
                }
            }

            # Process any accessor declarations
            if ($decl) {
                create_accessors($pkg, $fld, $decl);
            }

            # Save hash/array refs
            push(@{$FIELDS{$pkg}}, $fld);
        }
    }
    undef(%NEW_FIELDS);  # No longer needed
}


# Initialize as part of the CHECK phase
{
    no warnings 'void';
    CHECK {
        initialize();
    }
}


### Thread-Shared Object Support ###

# Contains flags as to whether or not a class is sharing objects between
# threads
#my %IS_SHARING;   # Declared above

sub set_sharing :Private
{
    my ($class, $sharing, $file, $line) = @_;
    $sharing = ($sharing) ? 1 : 0;

    if (exists($IS_SHARING{$class})) {
        if ($IS_SHARING{$class} != $sharing) {
            my (@loc, $nfile, $nline);
            if ($sharing) {
                @loc  = ($class, $file, $line);
                ($nfile, $nline) = (@{$IS_SHARING{$class}})[1..2];
            } else {
                @loc  = ($class, (@{$IS_SHARING{$class}})[1..2]);
                ($nfile, $nline) = ($file, $line);
            }
            OIO::Code->die(
                'location' => \@loc,
                'message'  => "Can't combine thread-sharing and non-sharing instances of a class in the same application",
                'Info'     => "Class '$class' was declared as sharing in '$file' line $line, but was declared as non-sharing in '$nfile' line $nline");
        }
    } else {
        $IS_SHARING{$class} = [ $sharing, $file, $line ];
    }
}


# Internal subroutine that determines if a class's objects are shared between
# threads
sub is_sharing :Private
{
    my $class = $_[0];
    return ($threads::shared::threads_shared
                && exists($IS_SHARING{$class})
                && $IS_SHARING{$class}[0]);
}


### Thread Cloning Support ###

# Thread cloning registry - maintains weak references to non-thread-shared
# objects for thread cloning
my %OBJECTS;

# Thread tracking registry - maintains thread lists for thread-shared objects
# to control object destruction
my %SHARED;
if ($threads::shared::threads_shared) {
    threads::shared::share(%SHARED);
}

# Thread ID is used to keep CLONE from executing more than once
#my $THREAD_ID = 0;   # Declared above


# Called after thread is cloned
sub CLONE
{
    # Don't execute when called for subclasses
    if ($_[0] ne __PACKAGE__) {
        return;
    }

    # Don't execute twice for same thread
    if ($THREAD_ID == threads->tid()) {
        return;
    }

    # Set thread ID for the above
    $THREAD_ID = threads->tid();

    # Process thread-shared objects
    if (keys(%SHARED)) {    # Need keys() due to bug in older Perls
        lock(%SHARED);

        # Add thread ID to every object in the thread tracking registry
        foreach my $class (keys(%SHARED)) {
            foreach my $oid (keys(%{$SHARED{$class}})) {
                push(@{$SHARED{$class}{$oid}}, $THREAD_ID);
            }
        }
    }

    # Process non-thread-shared objects
    foreach my $class (keys(%OBJECTS)) {
        # Get class tree
        my @tree = @{$TREE_TOP_DOWN{$class}};

        # Get the ID sub for this class, if any
        my $id_sub = $ID_SUBS{$class}[0];

        # Process each object in the class
        foreach my $old_id (keys(%{$OBJECTS{$class}})) {
            my $obj;
            if ($id_sub == \&_ID) {
                # Objects using internal ID sub keep their same ID
                $obj = $OBJECTS{$class}{$old_id};

            } else {
                # Get cloned object associated with old ID
                $obj = delete($OBJECTS{$class}{$old_id});

                # Unlock the object
                Internals::SvREADONLY($$obj, 0) if ($] >= 5.008003);

                # Replace the old object ID with a new one
                local $SIG{__DIE__} = 'OIO::trap';
                $$obj = $id_sub->($class);

                # Lock the object again
                Internals::SvREADONLY($$obj, 1) if ($] >= 5.008003);

                # Update the keys of the field arrays/hashes
                # with the new object ID
                foreach my $pkg (@tree) {
                    foreach my $fld (@{$FIELDS{$pkg}}) {
                        if (ref($fld) eq 'ARRAY') {
                            $$fld[$$obj] = delete($$fld[$old_id]);
                            if ($WEAK{$fld}) {
                                Scalar::Util::weaken($$fld[$$obj]);
                            }
                        } else {
                            $$fld{$$obj} = delete($$fld{$old_id});
                            if ($WEAK{$fld}) {
                                Scalar::Util::weaken($$fld{$$obj});
                            }
                        }
                    }
                }

                # Resave weakened reference to object
                Scalar::Util::weaken($OBJECTS{$class}{$$obj} = $obj);
            }

            # Dispatch any special replication handling
            if (%REPLICATORS) {
                my $pseudo_object = \do{ my $scalar = $old_id; };
                foreach my $pkg (@tree) {
                    if (my $replicate = $REPLICATORS{$pkg}) {
                        local $SIG{__DIE__} = 'OIO::trap';
                        $replicate->($pseudo_object, $obj, 'CLONE');
                    }
                }
            }
        }
    }
}


### Object Methods ###

my @EXPORT = qw(new clone set DESTROY);

# Helper subroutine to export methods to classes
sub export_methods :Private
{
    my @EXPORT_STORABLE = qw(STORABLE_freeze STORABLE_thaw);

    no strict 'refs';

    foreach my $pkg (keys(%TREE_TOP_DOWN)) {
        EXPORT:
        foreach my $sym (@EXPORT, ($pkg->isa('Storable')) ? @EXPORT_STORABLE : ()) {
            my $full_sym = $pkg.'::'.$sym;
            # Only export if method doesn't already exist,
            # and not overridden in a parent class
            if (! *{$full_sym}{CODE}) {
                foreach my $class (@{$TREE_BOTTOM_UP{$pkg}}) {
                    my $class_sym = $class.'::'.$sym;
                    if (*{$class_sym}{CODE} &&
                        (*{$class_sym}{CODE} != \&{$sym}))
                    {
                        next EXPORT;
                    }
                }
                *{$full_sym} = \&{$sym};
            }
        }
    }
}


# Helper subroutine to create a new 'bare' object
sub _obj :Private
{
    my $class = shift;

    # Create a new 'bare' object
    my $self = Object::InsideOut::Util::create_object($class,
                                                      $ID_SUBS{$class}[0]);

    # Thread support
    if (is_sharing($class)) {
        threads::shared::share($self);

        # Add thread tracking list for this thread-shared object
        lock(%SHARED);
        if (! exists($SHARED{$class})) {
            $SHARED{$class} = &threads::shared::share({});
        }
        $SHARED{$class}{$$self} = &threads::shared::share([]);
        push(@{$SHARED{$class}{$$self}}, $THREAD_ID);

    } elsif ($threads::threads) {
        # Add non-thread-shared object to thread cloning list
        Scalar::Util::weaken($OBJECTS{$class}{$$self} = $self);
    }

    return($self);
}


# Object Constructor
sub new
{
    my $thing = shift;
    my $class = ref($thing) || $thing;

    # Can't call ->new() on this package
    if ($class eq __PACKAGE__) {
        OIO::Method->die('message' => q/Can't create objects from 'Object::InsideOut' itself/);
    }

    # Perform package initialization, if required
    if ($DO_INIT) {
        initialize();
    }

    # Gather arguments into a single hash ref
    my $all_args = {};
    while (my $arg = shift) {
        if (ref($arg) eq 'HASH') {
            # Add args from a hash ref
            @{$all_args}{keys(%{$arg})} = values(%{$arg});
        } elsif (ref($arg)) {
            OIO::Args->die(
                'message'  => "Bad initializer: @{[ref($arg)]} ref not allowed",
                'Usage'    => q/Args must be 'key=>val' pair(s) and\/or hash ref(s)/);
        } elsif (! @_) {
            OIO::Args->die(
                'message'  => "Bad initializer: Missing value for key '$arg'",
                'Usage'    => q/Args must be 'key=>val' pair(s) and\/or hash ref(s)/);
        } else {
            # Add 'key => value' pair
            $$all_args{$arg} = shift;
        }
    }

    # Create a new 'bare' object
    my $self = _obj($class);

    # Execute pre-initialization subroutines
    foreach my $pkg (@{$TREE_BOTTOM_UP{$class}}) {
        my $preinit = $PREINITORS{$pkg};
        if ($preinit) {
            local $SIG{__DIE__} = 'OIO::trap';
            $self->$preinit($all_args);
        }
    }

    # Initialize object
    foreach my $pkg (@{$TREE_TOP_DOWN{$class}}) {
        my $spec = $INIT_ARGS{$pkg};
        my $init = $INITORS{$pkg};

        # Nothing to initialize for this class
        next if (!$spec && !$init);

        # If have InitArgs, then process args with it.  Otherwise, all the
        # args will be sent to the Init subroutine.
        my $args = ($spec) ? Object::InsideOut::Util::process_args($pkg,
                                                                   $self,
                                                                   $spec,
                                                                   $all_args)
                           : $all_args;

        if ($init) {
            # Send remaining args, if any, to Init subroutine
            local $SIG{__DIE__} = 'OIO::trap';
            $self->$init($args);

        } elsif (%$args) {
            # It's an error if no Init subroutine, and there are unhandled
            # args
            OIO::Args->die(
                'message' => "Unhandled arguments for class '$class': " . join(', ', keys(%$args)),
                'Usage'   => q/Add appropriate 'Field =>' designators to the :InitArgs hash/);
        }
    }

    # Done - return object
    return ($self);
}


# Creates a copy of an object
sub clone
{
    my ($parent, $deep) = @_;        # Parent object and deep cloning flag
    $deep = ($deep) ? 'deep' : '';   # Deep clone the object?

    # Must call ->clone() as an object method
    my $class = Scalar::Util::blessed($parent);
    if (! $class) {
        OIO::Method->die('message'  => q/Must call ->clone() as an object method/);
    }

    # Create a new 'bare' object
    my $clone = _obj($class);

    # Flag for shared class
    my $am_sharing = is_sharing($class);

    # Clone the object
    foreach my $pkg (@{$TREE_TOP_DOWN{$class}}) {
        # Clone field data from the parent
        foreach my $fld (@{$FIELDS{$pkg}}) {
            my $fdeep = $deep || $DEEP_CLONE{$fld};  # Deep clone the field?
            lock($fld) if ($am_sharing);
            if (ref($fld) eq 'ARRAY') {
                if ($fdeep && $am_sharing) {
                    $$fld[$$clone] = Object::InsideOut::Util::shared_clone($$fld[$$parent]);
                } elsif ($fdeep) {
                    $$fld[$$clone] = Object::InsideOut::Util::clone($$fld[$$parent]);
                } else {
                    $$fld[$$clone] = $$fld[$$parent];
                }
                if ($WEAK{$fld}) {
                    Scalar::Util::weaken($$fld[$$clone]);
                }
            } else {
                if ($fdeep && $am_sharing) {
                    $$fld{$$clone} = Object::InsideOut::Util::shared_clone($$fld{$$parent});
                } elsif ($fdeep) {
                    $$fld{$$clone} = Object::InsideOut::Util::clone($$fld{$$parent});
                } else {
                    $$fld{$$clone} = $$fld{$$parent};
                }
                if ($WEAK{$fld}) {
                    Scalar::Util::weaken($$fld{$$clone});
                }
            }
        }

        # Dispatch any special replication handling
        if (my $replicate = $REPLICATORS{$pkg}) {
            local $SIG{__DIE__} = 'OIO::trap';
            $parent->$replicate($clone, $deep);
        }
    }

    # Done - return clone
    return ($clone);
}


# Put data in a field, making sure that sharing is supported
sub set
{
    my ($self, $field, $data) = @_;

    # Check usage
    if (! defined($field)) {
        OIO::Args->die(
            'message'  => 'Missing field argument',
            'Usage'    => '$obj->set($field_ref, $data)');
    }
    my $fld_type = ref($field);
    if (! $fld_type || ($fld_type ne 'ARRAY' && $fld_type ne 'HASH')) {
        OIO::Args->die(
            'message' => 'Invalid field argument',
            'Usage'   => '$obj->set($field_ref, $data)');
    }

    # Check data
    if ($WEAK{$field} && ! ref($data)) {
        OIO::Args->die(
            'message'  => "Bad argument: $data",
            'Usage'    => q/Argument to specified field must be a reference/);
    }

    # Handle sharing
    if ($threads::shared::threads_shared &&
        threads::shared::_id($field))
    {
        lock($field);
        if ($fld_type eq 'ARRAY') {
            $$field[$$self] = Object::InsideOut::Util::make_shared($data);
        } else {
            $$field{$$self} = Object::InsideOut::Util::make_shared($data);
        }

    } else {
        # No sharing - just store the data
        if ($fld_type eq 'ARRAY') {
            $$field[$$self] = $data;
        } else {
            $$field{$$self} = $data;
        }
    }

    # Weaken data, if required
    if ($WEAK{$field}) {
        if ($fld_type eq 'ARRAY') {
            Scalar::Util::weaken($$field[$$self]);
        } else {
            Scalar::Util::weaken($$field{$$self});
        }
    }
}


# Object Destructor
sub DESTROY
{
    my $self  = shift;
    my $class = ref($self);

    if ($$self) {
        my $is_sharing = is_sharing($class);
        if ($is_sharing) {
            # Thread-shared object

            local $SIG{__WARN__} = sub { };     # Suppress spurious msg
            if (keys(%SHARED)) {                # Perl bug workaround
                if (! exists($SHARED{$class}{$$self})) {
                    print(STDERR "ERROR: Attempt to DESTROY object ID $$self of class $class in thread ID $THREAD_ID twice\n");
                    return;   # Object already deleted (shouldn't happen)
                }

                # Remove thread ID from this object's thread tracking list
                lock(%SHARED);
                if (@{$SHARED{$class}{$$self}} =
                        grep { $_ != $THREAD_ID } @{$SHARED{$class}{$$self}})
                {
                    return;
                }

                # Delete the object from the thread tracking registry
                delete($SHARED{$class}{$$self});
            }

        } elsif ($threads::threads) {
            if (! exists($OBJECTS{$class}{$$self})) {
                print(STDERR "ERROR: Attempt to DESTROY object ID $$self of class $class twice\n");
                return;
            }

            # Delete this non-thread-shared object from the thread cloning
            # registry
            delete($OBJECTS{$class}{$$self});
        }

        # Destroy object
        foreach my $pkg (@{$TREE_BOTTOM_UP{$class}}) {
            # Dispatch any special destruction handling
            if (my $destroy = $DESTROYERS{$pkg}) {
                local $SIG{__DIE__} = 'OIO::trap';
                $self->$destroy();
            }

            # Delete object field data
            foreach my $fld (@{$FIELDS{$pkg}}) {
                # If sharing, then must lock object field
                lock($fld) if ($is_sharing);
                if (ref($fld) eq 'HASH') {
                    delete($$fld{$$self});
                } else {
                    delete($$fld[$$self]);
                }
            }
        }

        # Reclaim the object ID if applicable
        if ($ID_SUBS{$class}[0] == \&_ID) {
            _ID($class, $$self);
        }

        # Unlock the object
        Internals::SvREADONLY($$self, 0) if ($] >= 5.008003);
        # Erase the object ID - just in case
        $$self = undef;
    }
}


### Serialization support using Storable ###

sub STORABLE_freeze {
    my ($self, $cloning) = @_;
    return ('', $self->dump());
}

sub STORABLE_thaw {
    my ($obj, $cloning, $data);
    if (@_ == 4) {
        ($obj, $cloning, undef, $data) = @_;
    } else {
        # Backward compatibility
        ($obj, $cloning, $data) = @_;
    }

    # Recreate the object
    my $self = Object::InsideOut->pump($data);
    # Transfer the ID to Storable's object
    $$obj = $$self;
    # Make object shared, if applicable
    if (is_sharing(ref($obj))) {
        threads::shared::share($obj);
    }
    # Make object readonly
    if ($] >= 5.008003) {
        Internals::SvREADONLY($$obj, 1);
        Internals::SvREADONLY($$self, 0);
    }
    # Prevent object destruction
    undef($$self);
}


### Accessor Generator ###

# Creates object data accessors for classes
sub create_accessors :Private
{
    my ($package, $field_ref, $decl) = @_;

    # Parse the accessor declaration
    my $acc_spec;
    {
        my @errs;
        local $SIG{__WARN__} = sub { push(@errs, @_); };

        if ($decl =~ /^{/) {
            eval "\$acc_spec = $decl";
        } else {
            eval "\$acc_spec = { $decl }";
        }

        if ($@ || @errs) {
            my ($err) = split(/ at /, $@ || join(" | ", @errs));
            OIO::Attribute->die(
                'message'   => "Malformed attribute in package '$package'",
                'Error'     => $err,
                'Attribute' => "Field( $decl )");
        }
    }

    # Get info for accessors
    my ($get, $set, $type, $name, $return, $private, $restricted);
    foreach my $key (keys(%{$acc_spec})) {
        my $key_uc = uc($key);
        my $val = $$acc_spec{$key};
        # Standard accessors
        if ($key =~ /^st.*d/i) {
            $get = 'get_' . $val;
            $set = 'set_' . $val;
        }
        # Get and/or set accessors
        elsif ($key =~ /^acc|^com|^mut|[gs]et/i) {
            # Get accessor
            if ($key =~ /acc|com|mut|get/i) {
                $get = $val;
            }
            # Set accessor
            if ($key =~ /acc|com|mut|set/i) {
                $set = $val;
            }
        }
        # Deep clone the field
        elsif ($key_uc eq 'COPY' || $key_uc eq 'CLONE') {
            if (uc($val) eq 'DEEP') {
                $DEEP_CLONE{$field_ref} = 1;
            }
            next;
        } elsif ($key_uc eq 'DEEP') {
            if ($val) {
                $DEEP_CLONE{$field_ref} = 1;
            }
            next;
        }
        # Store weakened refs
        elsif ($key_uc =~ /^WEAK/) {
            if ($val) {
                $WEAK{$field_ref} = 1;
            }
            next;
        }
        # Field type checking for set accessor
        elsif ($key_uc eq 'TYPE') {
            $type = $val;
        }
        # Field name for ->dump()
        elsif ($key_uc eq 'NAME') {
            $name = $val;
        }
        # Set accessor return type
        elsif ($key =~ /^ret(?:urn)?$/i) {
            $return = uc($val);
        }
        # Set accessor permission
        elsif ($key =~ /^perm|^priv|^restrict/i) {
            if ($key =~ /^perm/i) {
                $key = $val;
                $val = 1;
            }
            if ($key =~ /^priv/i) {
                $private = $val;
            }
            if ($key =~ /^restrict/i) {
                $restricted = $val;
            }
        }
        # Unknown parameter
        else {
            OIO::Attribute->die(
                'message' => "Can't create accessor method for package '$package'",
                'Info'    => "Unknown accessor specifier: $key");
        }
        # $val must have a usable value
        if (! defined($val) || $val eq '') {
            OIO::Attribute->die(
                'message'   => "Invalid '$key' entry in :Field attribute",
                'Attribute' => "Field( $decl )");
        }
    }

    # Add field info for dump()
    if ($name) {
        if (exists($DUMP_FIELDS{$package}{$name}) &&
            $field_ref != $DUMP_FIELDS{$package}{$name}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$package'",
                'Info'      => "'$name' already specified for another field using '$DUMP_FIELDS{$package}{$name}[1]'",
                'Attribute' => "Field( $decl )");
        }
        $DUMP_FIELDS{$package}{$name} = [ $field_ref, 'Name' ];
        # Done if only 'Name' present
        if (! $get && ! $set && ! $type && ! $return) {
            return;
        }

    } elsif ($get) {
        if (exists($DUMP_FIELDS{$package}{$get}) &&
            $field_ref != $DUMP_FIELDS{$package}{$get}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$package'",
                'Info'      => "'$get' already specified for another field using '$DUMP_FIELDS{$package}{$get}[1]'",
                'Attribute' => "Field( $decl )");
        }
        $DUMP_FIELDS{$package}{$get} = [ $field_ref, 'Get' ];

    } elsif ($set) {
        if (exists($DUMP_FIELDS{$package}{$set}) &&
            $field_ref != $DUMP_FIELDS{$package}{$set}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$package'",
                'Info'      => "'$set' already specified for another field using '$DUMP_FIELDS{$package}{$set}[1]'",
                'Attribute' => "Field( $decl )");
        }
        $DUMP_FIELDS{$package}{$set} = [ $field_ref, 'Set' ];
    }

    # If 'TYPE' and/or 'RETURN', need 'SET', too
    if (($type || $return) && ! $set) {
        OIO::Attribute->die(
            'message'   => "Can't create accessor method for package '$package'",
            'Info'      => "No set accessor specified to go with 'TYPE'/'RETURN' keyword",
            'Attribute' => "Field( $decl )");
    }

    # Check for name conflict
    foreach my $method ($get, $set) {
        if ($method) {
            no strict 'refs';
            # Do not overwrite existing methods
            if (*{$package.'::'.$method}{CODE}) {
                OIO::Attribute->die(
                    'message'   => q/Can't create accessor method/,
                    'Info'      => "Method '$method' already exists in class '$package'",
                    'Attribute' => "Field( $decl )");
            }
        }
    }

    # Check type-checking setting and set default
    if (! defined($type)) {
        $type = 'NONE';
    } elsif (!$type) {
        OIO::Attribute->die(
            'message'   => q/Can't create accessor method/,
            'Info'      => q/Invalid setting for 'TYPE'/,
            'Attribute' => "Field( $decl )");
    } elsif ($type =~ /^num(?:ber|eric)?/i) {
        $type = 'NUMERIC';
    } elsif (uc($type) eq 'LIST' || uc($type) eq 'ARRAY') {
        $type = 'ARRAY';
    } elsif (uc($type) eq 'HASH') {
        $type = 'HASH';
    }

    # Check return type and set default
    if (! defined($return) || $return eq 'NEW') {
        $return = 'NEW';
    } elsif ($return eq 'OLD' || $return =~ /^PREV(?:IOUS)?$/ || $return eq 'PRIOR') {
        $return = 'OLD';
    } elsif ($return eq 'SELF' || $return =~ /^OBJ(?:ECT)?$/) {
        $return = 'SELF';
    } else {
        OIO::Attribute->die(
            'message'   => q/Can't create accessor method/,
            'Info'      => "Invalid setting for 'RETURN': $return",
            'Attribute' => "Field( $decl )");
    }

    # Code to be eval'ed into subroutines
    my $code = "package $package;\n";

    # Create 'set' or combination accessor
    if (defined($set)) {
        # Begin with subroutine declaration in the appropriate package
        $code .= "*${package}::$set = sub {\n";

        # Check accessor permission
        if ($private) {
            $code .= <<"_PRIVATE_";
    my \$caller = caller();
    if (\$caller ne '$package') {
        OIO::Method->die(
            'message' => "Can't call private method '$package->$set' from class '\$caller'",
            'location' => [ caller() ]);
    }
_PRIVATE_
        } elsif ($restricted) {
            $code .= <<"_RESTRICTED_";
    my \$caller = caller();
    if (! \$caller->isa('$package') && ! $package->isa(\$caller)) {
        OIO::Method->die(
            'message'  => "Can't call restricted method '$package->$set' from class '\$caller'",
            'location' => [ caller() ]);
    }
_RESTRICTED_
        }

        # Lock the field if sharing
        if (is_sharing($package)) {
            $code .= "    lock(\$field);\n"
        }

        # Add GET portion for combination accessor
        if (defined($get) && $get eq $set) {
            if (ref($field_ref) eq 'HASH') {
                $code .= <<"_COMBINATION_";
    if (\@_ == 1) {
        return (\$\$field\{\${\$_[0]}});
    }
_COMBINATION_
            } else {
                $code .= <<"_COMBINATION_";
    if (\@_ == 1) {
        return (\$\$field\[\${\$_[0]}]);
    }
_COMBINATION_
            }
            undef($get);  # That it for 'GET'
        }

        # Else check that set was called with at least one arg
        else {
            $code .= <<"_CHECK_ARGS_";
    if (\@_ < 2) {
        OIO::Args->die(
            'message'  => q/Missing arg(s) to '$package->$set'/,
            'location' => [ caller() ]);
    }
_CHECK_ARGS_
        }

        # Add data type checking
        if (ref($type)) {
            if (ref($type) ne 'CODE') {
                OIO::Attribute->die(
                    'message'   => q/Can't create accessor method/,
                    'Info'      => q/'Type' must be a 'string' or code ref/,
                    'Attribute' => "Field( $decl )");
            }

            $code .= <<"_CODE_";
    my (\$arg, \$ok, \@errs);
    local \$SIG{__WARN__} = sub { push(\@errs, \@_); };
    eval { \$ok = \$type->(\$arg = \$_[1]) };
    if (\$@ || \@errs) {
        my (\$err) = split(/ at /, \$@ || join(" | ", \@errs));
        OIO::Code->die(
            'message' => q/Problem with type check routine for '$package->$set'/,
            'Error'   => \$err);
    }
    if (! \$ok) {
        OIO::Args->die(
            'message'  => "Argument to '$package->$set' failed type check: \$arg",
            'location' => [ caller() ]);
    }
_CODE_

        } elsif ($type eq 'NONE') {
            # For 'weak' fields, the data must be a ref
            if ($WEAK{$field_ref}) {
                $code .= <<"_WEAK_";
    my \$arg;
    if (! ref(\$arg = \$_[1])) {
        OIO::Args->die(
            'message'  => "Bad argument: \$arg",
            'Usage'    => q/Argument to '$package->$set' must be a reference/,
            'location' => [ caller() ]);
    }
_WEAK_
            } else {
                # No data type check required
                $code .= "    my \$arg = \$_[1];\n";
            }

        } elsif ($type eq 'NUMERIC') {
            # One numeric argument
            $code .= <<"_NUMERIC_";
    my \$arg;
    if (! Scalar::Util::looks_like_number(\$arg = \$_[1])) {
        OIO::Args->die(
            'message'  => "Bad argument: \$arg",
            'Usage'    => q/Argument to '$package->$set' must be numeric/,
            'location' => [ caller() ]);
    }
_NUMERIC_

        } elsif ($type eq 'ARRAY') {
            # List/array - 1+ args or array ref
            $code .= <<'_ARRAY_';
    my $arg;
    if (@_ == 2 && ref($_[1]) eq 'ARRAY') {
        $arg = $_[1];
    } else {
        my @args = @_;
        shift(@args);
        $arg = \@args;
    }
_ARRAY_

        } elsif ($type eq 'HASH') {
            # Hash - pairs of args or hash ref
            $code .= <<"_HASH_";
    my \$arg;
    if (\@_ == 2 && ref(\$_[1]) eq 'HASH') {
        \$arg = \$_[1];
    } elsif (\@_ % 2 == 0) {
        OIO::Args->die(
            'message'  => q/Odd number of arguments: Can't create hash ref/,
            'Usage'    => q/'$package->$set' requires a hash ref or an even number of args (to make a hash ref)/,
            'location' => [ caller() ]);
    } else {
        my \@args = \@_;
        shift(\@args);
        my \%args = \@args;
        \$arg = \\\%args;
    }
_HASH_

        } else {
            # Support explicit specification of array refs and hash refs
            if (uc($type) =~ /^ARRAY_?REF$/) {
                $type = 'ARRAY';
            } elsif (uc($type) =~ /^HASH_?REF$/) {
                $type = 'HASH';
            }

            # One object or ref arg - exact spelling and case required
            $code .= <<"_REF_";
    my \$arg;
    if (! Object::InsideOut::Util::is_it(\$arg = \$_[1], '$type')) {
        OIO::Args->die(
            'message'  => q/Bad argument: Wrong type/,
            'Usage'    => q/Argument to '$package->$set' must be of type '$type'/,
            'location' => [ caller() ]);
    }
_REF_
        }

        # Grab 'OLD' value
        if ($return eq 'OLD') {
            if (ref($field_ref) eq 'HASH') {
                $code .= "    my \$ret = \$\$field\{\${\$_[0]}};\n";
            } else {
                $code .= "    my \$ret = \$\$field\[\${\$_[0]}];\n";
            }
        }

        # Add actual 'set' code
        if (ref($field_ref) eq 'HASH') {
            $code .= (is_sharing($package))
                  ? "    \$\$field\{\${\$_[0]}} = Object::InsideOut::Util::make_shared(\$arg);\n"
                  : "    \$\$field\{\${\$_[0]}} = \$arg;\n";
            if ($WEAK{$field_ref}) {
                $code .= "    Scalar::Util::weaken(\$\$field\{\${\$_[0]}});\n";
            }
        } else {
            $code .= (is_sharing($package))
                  ? "    \$\$field\[\${\$_[0]}] = Object::InsideOut::Util::make_shared(\$arg);\n"
                  : "    \$\$field\[\${\$_[0]}] = \$arg;\n";
            if ($WEAK{$field_ref}) {
                $code .= "    Scalar::Util::weaken(\$\$field\[\${\$_[0]}]);\n";
            }
        }


        # Add code for return value
        if ($return eq 'SELF') {
            $code .= "    return (\$_[0]);\n";
        } elsif ($return eq 'OLD') {
            $code .= "    return (\$ret);\n";
        }

        # Done
        $code .= "};\n";
    }

    # Create 'get' accessor
    if (defined($get)) {
        $code .= "*${package}::$get = sub {\n";

        # Check accessor permission
        if ($private) {
            $code .= <<"_PRIVATE_";
    my \$caller = caller();
    if (\$caller ne '$package') {
        OIO::Method->die(
            'message' => "Can't call private method '$package->$get' from class '\$caller'",
            'location' => [ caller() ]);
    }
_PRIVATE_
        } elsif ($restricted) {
            $code .= <<"_RESTRICTED_";
    my \$caller = caller();
    if (! \$caller->isa('$package') && ! $package->isa(\$caller)) {
        OIO::Method->die(
            'message'  => "Can't call restricted method '$package->$get' from class '\$caller'",
            'location' => [ caller() ]);
    }
_RESTRICTED_
        }

        # Set up locking code
        my $lock = (is_sharing($package)) ? "    lock(\$field);\n" : '';

        # Build subroutine text
        if (ref($field_ref) eq 'HASH') {
            $code .= <<"_GET_";
$lock    \$\$field{\${\$_[0]}};
};
_GET_
        } else {
            $code .= <<"_GET_";
$lock    \$\$field[\${\$_[0]}];
};
_GET_
        }
    }

    # Compile the subroutine(s) in the smallest possible lexical scope
    my @errs;
    local $SIG{__WARN__} = sub { push(@errs, @_); };
    {
        my $field = $field_ref;
        eval $code;
    }
    if ($@ || @errs) {
        my ($err) = split(/ at /, $@ || join(" | ", @errs));
        OIO::Internal->die(
            'message'     => "Failure creating accessor for class '$package'",
            'Error'       => $err,
            'Declaration' => $decl,
            'Code'        => $code,
            'self'        => 1);
    }
}


### Method/subroutine Access Control ###

# Returns a 'wrapper' closure back to initialize() that restricts a method
# to being only callable from within its class hierarchy
sub create_RESTRICTED :Private
{
    my ($package, $method, $code) = @_;
    return sub {
        my $caller = caller();
        # Caller must be in class hierarchy
        if ($caller->$UNIV_ISA($package) || $package->$UNIV_ISA($caller)) {
            goto $code;
        }
        OIO::Method->die('message'  => "Can't call restricted method '$package->$method' from class '$caller'");
    };
}


# Returns a 'wrapper' closure back to initialize() that makes a method
# private (i.e., only callable from within its own class).
sub create_PRIVATE :Private
{
    my ($package, $method, $code) = @_;
    return sub {
        my $caller = caller();
        # Caller must be in the package
        if ($caller eq $package) {
            goto $code;
        }
        OIO::Method->die('message' => "Can't call private method '$package->$method' from class '$caller'");
    };
}


# Redefines a subroutine to make it uncallable - with the original code ref
# stored elsewhere, of course.
sub create_HIDDEN :Private
{
    my ($package, $method) = @_;

    # Create new code that hides the original method
    my $code = <<"_CODE_";
sub ${package}::$method {
    OIO::Method->die('message'  => q/Can't call hidden method '$package->$method'/);
}
_CODE_

    # Eval the new code
    my @errs;
    local $SIG{__WARN__} = sub { push(@errs, @_); };
    no warnings 'redefine';

    eval $code;

    if ($@ || @errs) {
        my ($err) = split(/ at /, $@ || join(" | ", @errs));
        OIO::Internal->die(
            'message'  => "Failure hiding '$package->$method'",
            'Error'    => $err,
            'Code'     => $code,
            'self'     => 1);
    }
}


### Delayed Loading ###

# Loads sub-modules
sub load :Private
{
    my $mod = shift;
    my $file = "Object/InsideOut/$mod.pm";

    if (! exists($INC{$file})) {
        # Load the file
        my $rc = do($file);

        # Check for errors
        if ($@) {
            OIO::Internal->die(
                'message'     => "Failure compiling file '$file'",
                'Error'       => $@,
                'self'        => 1);
        } elsif (! defined($rc)) {
            OIO::Internal->die(
                'message'     => "Failure reading file '$file'",
                'Error'       => $!,
                'self'        => 1);
        } elsif (! $rc) {
            OIO::Internal->die(
                'message'     => "Failure processing file '$file'",
                'Error'       => $rc,
                'self'        => 1);
        }
    }
}

sub generate_CUMULATIVE :Private
{
    load('Cumulative');
    goto &generate_CUMULATIVE;
}

sub create_CUMULATIVE :Private
{
    load('Cumulative');
    goto &create_CUMULATIVE;
}

sub generate_CHAINED :Private
{
    load('Chained');
    goto &generate_CHAINED;
}

sub create_CHAINED :Private
{
    load('Chained');
    goto &create_CHAINED;
}

sub generate_OVERLOAD :Private
{
    load('Overload');
    goto &generate_OVERLOAD;
}

sub install_UNIVERSAL
{
    load('Universal');

    @_ = (\&UNIVERSAL::isa, \&UNIVERSAL::can, \%AUTOMETHODS,
          \%HERITAGE, \%TREE_BOTTOM_UP);

    goto &install_UNIVERSAL;
}

sub dump
{
    load('Dump');

    push(@EXPORT, 'dump');
    $DO_INIT = 1;

    @_ = (\@DUMP_INITARGS, \%DUMP_FIELDS, \%DUMPERS, \%PUMPERS,
          \%INIT_ARGS, \%TREE_TOP_DOWN, \%FIELDS, 'dump', @_);

    goto &dump;
}

sub pump
{
    load('Dump');

    push(@EXPORT, 'dump');
    $DO_INIT = 1;

    @_ = (\@DUMP_INITARGS, \%DUMP_FIELDS, \%DUMPERS, \%PUMPERS,
          \%INIT_ARGS, \%TREE_TOP_DOWN, \%FIELDS, 'pump', @_);

    goto &dump;
}

sub inherit
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'inherit', @_);

    goto &inherit;
}

sub heritage
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'heritage', @_);

    goto &inherit;
}

sub disinherit
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'disinherit', @_);

    goto &inherit;
}

sub create_heritage
{
    # Private
    my $caller = caller();
    if ($caller ne __PACKAGE__) {
        OIO::Method->die('message' => "Can't call private subroutine 'Object::InsideOut::create_heritage' from class '$caller'");
    }

    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'create_heritage', @_);

    goto &inherit;
}

sub create_field
{
    load('Dynamic');

    unshift(@_, $UNIV_ISA);

    goto &create_field;
}

sub AUTOLOAD
{
    load('Autoload');

    push(@EXPORT, 'AUTOLOAD');
    $DO_INIT = 1;

    @_ = (\%TREE_TOP_DOWN, \%TREE_BOTTOM_UP, \%HERITAGE, \%AUTOMETHODS, @_);

    goto &Object::InsideOut::AUTOLOAD;
}

}  # End of package's lexical scope

1;

__END__

=head1 NAME

Object::InsideOut - Comprehensive inside-out object support module

=head1 VERSION

This document describes Object::InsideOut version 1.45

=head1 SYNOPSIS

 package My::Class; {
     use Object::InsideOut;

     # Numeric field with combined get+set accessor
     my @data :Field('Accessor' => 'data', 'Type' => 'NUMERIC');

     # Takes 'DATA' (or 'data', etc.) as a manatory parameter to ->new()
     my %init_args :InitArgs = (
         'DATA' => {
             'Regex'     => qr/^data$/i,
             'Mandatory' => 1,
             'Type'      => 'NUMERIC',
         },
     );

     # Handle class-specific args as part of ->new()
     sub init :Init
     {
         my ($self, $args) = @_;

         $self->set(\@data, $args->{'DATA'});
     }
 }

 package My::Class::Sub; {
     use Object::InsideOut qw(My::Class);

     # List field with standard 'get_X' and 'set_X' accessors
     my @info :Field('Standard' => 'info', 'Type' => 'LIST');

     # Takes 'INFO' as an optional list parameter to ->new()
     # Value automatically added to @info array
     # Defaults to [ 'empty' ]
     my %init_args :InitArgs = (
         'INFO' => {
             'Type'    => 'LIST',
             'Field'   => \@info,
             'Default' => 'empty',
         },
     );
 }

 package main;

 my $obj = My::Class::Sub->new('Data' => 69);
 my $info = $obj->get_info();               # [ 'empty' ]
 my $data = $obj->data();                   # 69
 $obj->data(42);
 $data = $obj->data();                      # 42

 $obj = My::Class::Sub->new('INFO' => 'help', 'DATA' => 86);
 $data = $obj->data();                      # 86
 $info = $obj->get_info();                  # [ 'help' ]
 $obj->set_info(qw(foo bar baz));
 $info = $obj->get_info();                  # [ 'foo', 'bar', 'baz' ]

=head1 DESCRIPTION

This module provides comprehensive support for implementing classes using the
inside-out object model.

This module implements inside-out objects as anonymous scalar references that
are blessed into a class with the scalar containing the ID for the object
(usually a sequence number).  For Perl 5.8.3 and later, the scalar reference
is set as B<readonly> to prevent I<accidental> modifications to the ID.
Object data (i.e., fields) are stored within the class's package in either
arrays indexed by the object's ID, or hashes keyed to the object's ID.

The virtues of the inside-out object model over the I<blessed hash> object
model have been extolled in detail elsewhere.  See the informational links
under L</"SEE ALSO">.  Briefly, inside-out objects offer the following
advantages over I<blessed hash> objects:

=over

=item * Encapsulation

Object data is enclosed within the class's code and is accessible only through
the class-defined interface.

=item * Field Name Collision Avoidance

Inheritance using I<blessed hash> classes can lead to conflicts if any classes
use the same name for a field (i.e., hash key).  Inside-out objects are immune
to this problem because object data is stored inside each class's package, and
not in the object itself.

=item * Compile-time Name Checking

A common error with I<blessed hash> classes is the misspelling of field names:

 $obj->{'coment'} = 'Say what?';   # Should be 'comment' not 'coment'

As there is no compile-time checking on hash keys, such errors do not usually
manifest themselves until runtime.

With inside-out objects, I<text> hash keys are not used for accessing field
data.  Field names and the data index (i.e., $$self) are checked by the Perl
compiler such that any typos are easily caught using S<C<perl -c>>.

 $coment[$$self] = $value;    # Causes a compile-time error
    # or with hash-based fields
 $comment{$$slef} = $value;   # Also causes a compile-time error

=back

This module offers all the capabilities of other inside-out object modules
with the following additional key advantages:

=over

=item * Speed

When using arrays to store object data, Object::InsideOut objects are as
much as 40% faster than I<blessed hash> objects for fetching and setting data,
and even with hashes they are still several percent faster than I<blessed
hash> objects.

=item * Threads

Object::InsideOut is thread safe, and thoroughly supports sharing objects
between threads using L<threads::shared>.

=item * Flexibility

Allows control over object ID specification, accessor naming, parameter name
matching, and more.

=item * Runtime Support

Supports classes that may be loaded at runtime (i.e., using
S<C<eval { require ...; };>>).  This makes it usable from within L<mod_perl>,
as well.  Also supports dynamic creation of object fields during runtime.

=item * Perl 5.6 and 5.8

Tested on Perl v5.6.0 through v5.6.2, v5.8.0 through v5.8.8, and v5.9.3.

=item * Exception Objects

As recommended in I<Perl Best Practices>, Object::InsideOut uses
L<Exception::Class> for handling errors in an OO-compatible manner.

=item * Object Serialization

Object::InsideOut has built-in support for object dumping and reloading that
can be accomplished in either an automated fashion or through the use of
class-supplied subroutines.  Serialization using L<Storable> is also supported.

=item * Foreign Class Inheritance

Object::InsideOut allows classes to inherit from foreign (i.e.,
non-Object::InsideOut) classes, thus allowing you to sub-class other Perl
class, and access their methods from your own objects.

=back

=head2 Class Declarations

To use this module, your classes will start with S<C<use Object::InsideOut;>>:

 package My::Class; {
     use Object::InsideOut;
     ...
 }

Sub-classes inherit from base classes by telling Object::InsideOut what the
parent class is:

 package My::Sub; {
     use Object::InsideOut qw(My::Parent);
     ...
 }

Multiple inheritance is also supported:

 package My::Project; {
     use Object::InsideOut qw(My::Class Another::Class);
     ...
 }

Object::InsideOut acts as a replacement for the C<base> pragma:  It loads the
parent module(s), calls their C<import> functions, and sets up the sub-class's
@ISA array.  Therefore, you should not S<C<use base ...>> yourself, or try to
set up C<@ISA> arrays.

If a parent class takes parameters (e.g., symbols to be exported via
L<Exporter|/"Usage With C<Exporter>">), enclose them in an array ref
(mandatory) following the name of the parent class:

 package My::Project; {
     use Object::InsideOut 'My::Class'      => [ 'param1', 'param2' ],
                           'Another::Class' => [ 'param' ];
     ...
 }

=head2 Field Declarations

Object data fields consist of arrays within a class's package into which data
are stored using the object's ID as the array index.  An array is declared as
being an object field by following its declaration with the C<:Field>
attribute:

 my @info :Field;

Object data fields may also be hashes:

 my %data :Field;

However, as array access is as much as 40% faster than hash access, you should
stick to using arrays.  (See L</"Object ID"> concerning when hashes may be
required.)

(The case of the word I<Field> does not matter, but by convention should not
be all lowercase.)

=head2 Object Creation

Objects are created using the C<-E<gt>new()> method which is exported by
Object::InsideOut to each class:

 my $obj = My::Class->new();

Classes do not (normally) implement their own C<-E<gt>new()> method.
Class-specific object initialization actions are handled by C<:Init> labeled
methods (see L</"Object Initialization">).

Parameters are passed in as combinations of S<C<key =E<gt> value>> pairs
and/or hash refs:

 my $obj = My::Class->new('param1' => 'value1');
     # or
 my $obj = My::Class->new({'param1' => 'value1'});
     # or even
 my $obj = My::Class->new(
     'param_X' => 'value_X',
     'param_Y' => 'value_Y',
     {
         'param_A' => 'value_A',
         'param_B' => 'value_B',
     },
     {
         'param_Q' => 'value_Q',
     },
 );

Additionally, parameters can be segregated in hash refs for specific classes:

 my $obj = My::Class->new(
     'foo' => 'bar',
     'My::Class'      => { 'param' => 'value' },
     'Parent::Class'  => { 'data'  => 'info'  },
 );

The initialization methods for both classes in the above will get S<C<'foo'
=E<gt> 'bar'>>, C<My::Class> will also get S<C<'param' =E<gt> 'value'>>, and
C<Parent::Class> will also get S<C<'data' =E<gt> 'info'>>.  In this scheme,
class-specific parameters will override general parameters specified at a
higher level:

 my $obj = My::Class->new(
     'default' => 'bar',
     'Parent::Class'  => { 'default' => 'baz' },
 );

C<My::Class> will get S<C<'default' =E<gt> 'bar'>>, and C<Parent::Class> will
get S<C<'default' =E<gt> 'baz'>>.

Calling C<new> on an object works, too, and operates the same as calling
C<new> for the class of the object (i.e., C<$obj-E<gt>new()> is the same as
C<ref($obj)-E<gt>new()>).

NOTE: You cannot create objects from Object::InsideOut itself:

 # This is an error
 # my $obj = Object::InsideOut->new();

In this way, Object::InsideOut is not an object class, but functions more like
a pragma.

=head2 Object Cloning

Copies of objects can be created using the C<-E<gt>clone()> method which is
exported by Object::InsideOut to each class:

 my $obj2 = $obj->clone();

When called without arguments, C<-E<gt>clone()> creates a I<shallow> copy of
the object, meaning that any complex data structures (i.e., array, hash or
scalar refs) stored in the object will be shared with its clone.

Calling C<-E<gt>clone()> with a true argument:

 my $obj2 = $obj->clone(1);

creates a I<deep> copy of the object such that internally held array, hash
or scalar refs are I<replicated> and stored in the newly created clone.

I<Deep> cloning can also be controlled at the field level.  See L</"Field
Cloning"> below for more details.

Note that cloning does not clone internally held objects.  For example, if
C<$foo> contains a reference to C<$bar>, a clone of C<$foo> will also contain
a reference to C<$bar>; not a clone of C<$bar>.  If such behavior is needed,
it must be provided using a L<:Replicate|/"Object Replication"> subroutine.

=head2 Object Initialization

Object initialization is accomplished through a combination of an C<:InitArgs>
labeled hash (explained in detail in the L<next section|/"Object
Initialization Argument Specifications">), and an C<:Init> labeled
subroutine.

The C<:InitArgs> labeled hash specifies the parameters to be extracted from
the argument list supplied to the C<-E<gt>new()> method.  These parameters are
then sent to the C<:Init> labeled subroutine for processing:

 package My::Class; {
     my @my_field :Field;

     my %init_args :InitArgs = (
         'MY_PARAM' => qr/MY_PARAM/i,
     );

     sub _init :Init
     {
         my ($self, $args) = @_;

         if (exists($args->{'MY_PARAM'})) {
             $self->set(\@my_field, $args->{'MY_PARAM'});
         }
     }
 }

 package main;

 my $obj = My::Class->new('my_param' => 'data');

(The case of the words I<InitArgs> and I<Init> does not matter, but by
convention should not be all lowercase.)

This C<:Init> labeled subroutine will receive two arguments:  The newly
created object requiring further initialization (i.e., C<$self>), and a hash
ref of supplied arguments that matched C<:InitArgs> specifications.

Data processed by the subroutine may be placed directly into the class's field
arrays (hashes) using the object's ID (i.e., C<$$self>):

 $my_field[$$self] = $args->{'MY_PARAM'};

However, it is strongly recommended that you use the L<-E<gt>set()|/"Setting
Data"> method:

 $self->set(\@my_field, $args->{'MY_PARAM'});

which handles converting the data to a shared format when needed for
applications using L<threads::shared>.

=head2 Object Initialization Argument Specifications

The parameters to be handled by the C<-E<gt>new()> method are specified in a
hash that is labeled with the C<:InitArgs> attribute.

The simplest parameter specification is just a tag:

 my %init_args :InitArgs = (
     'DATA' => '',
 );

In this case, if a S<C<key =E<gt> value>> pair with an exact match of C<DATA>
for the key is found in the arguments sent to the C<-E<gt>new()> method, then
S<C<'DATA' =E<gt> value>> will be included in the argument hash ref sent to
the C<:Init> labeled subroutine.

=over

=item Parameter Name Matching

Rather than counting on exact matches, regular expressions can be used to
specify the parameter:

 my %init_args :InitArgs = (
     'Param' => qr/^PARA?M$/i,
 );

In this case, the argument key could be any of the following: PARAM, PARM,
Param, Parm, param, parm, and so on.  If a match is found, then S<C<'Param'
=E<gt> value>> is sent to the C<:Init> subroutine.  Note that the C<:InitArgs>
hash key is substituted for the original argument key.  This eliminates the
need for any parameter key pattern matching within the C<:Init> subroutine.

If additional parameter specifications (described below) are used, the syntax
changes, and the regular expression is moved inside a hash ref:

 my %init_args :InitArgs = (
     'Param' => {
         'Regex' => qr/^PARA?M$/i,
     },
 );

=item Mandatory Parameters

Mandatory parameters are declared as follows:

 my %init_args :InitArgs = (
     # Mandatory parameter requiring exact matching
     'INFO' => {
         'Mandatory' => 1,
     },
     # Mandatory parameter with pattern matching
     'input' => {
         'Regex'     => qr/^in(?:put)?$/i,
         'Mandatory' => 1,
     },
 );

If a mandatory parameter is missing from the argument list to C<new>, an error
is generated.

=item Default Values

For optional parameters, defaults can be specified:

 my %init_args :InitArgs = (
     'LEVEL' => {
         'Regex'   => qr/^lev(?:el)?|lvl$/i,
         'Default' => 3,
     },
 );

=item Type Checking

The parameter's type can also be specified:

 my %init_args :InitArgs = (
     'LEVEL' => {
         'Regex'   => qr/^lev(?:el)?|lvl$/i,
         'Default' => 3,
         'Type'    => 'Numeric',
     },
 );

Available types are:

=over

=item Numeric

Can also be specified as C<Num> or C<Number>.  This uses
Scalar::Util::looks_like_number to test the input value.

=item List

This type permits a single value (that is then placed in an array ref) or an
array ref.

=item A class name

The parameter's type must be of the specified class, or one of its
sub-classes (i.e., type checking is done using C<-E<gt>isa()>).  For example,
C<My::Class>.

=item Other reference type

The parameter's type must be of the specified reference type
(as returned by L<ref()|perlfunc/"ref EXPR">).  For example, C<CODE>.

=back

The first two types above are case-insensitive (e.g., 'NUMERIC', 'Numeric',
'numeric', etc.); the last two are case-sensitive.

The C<Type> keyword may also be paired with a code reference to provide custom
type checking.  The code ref can either be in the form of an anonymous
subroutine, or it can be derived from a (publicly accessible) subroutine.  The
result of executing the code ref on the initializer should be a boolean value.

 package My::Class; {
     use Object::InsideOut;

     # For initializer type checking, the subroutine can NOT be made 'Private'
     sub is_int {
         my $arg = $_[0];
         return (Scalar::Util::looks_like_number($arg) &&
                 (int($arg) == $arg));
     }

     my @level   :Field;
     my @comment :Field;

     my %init_args :InitArgs = (
         'LEVEL' => {
             'Field' => \@level,
             # Type checking using a named subroutine
             'Type'  => \&is_int,
         },
         'COMMENT' => {
             'Field' => \@comment,
             # Type checking using an anonymous subroutine
             'Type'  => sub { $_[0] ne '' }
         },
     );
 }

=item Automatic Processing

You can specify automatic processing for a parameter's value such that it is
placed directly into a field array/hash, and not sent to the C<:Init>
subroutine:

 my @hosts :Field;

 my %init_args :InitArgs = (
     'HOSTS' => {
         # Allow 'host' or 'hosts' - case-insensitive
         'Regex'     => qr/^hosts?$/i,
         # Mandatory parameter
         'Mandatory' => 1,
         # Allow single value or array ref
         'Type'      => 'List',
         # Automatically put the parameter into @hosts
         'Field'     => \@hosts,
     },
 );

In this case, when the host parameter is found, it is automatically put into
the C<@hosts> array, and a S<C<'HOSTS' =E<gt> value>> pair is B<not> sent to
the C<:Init> subroutine. In fact, if you specify fields for all your
parameters, then you don't even need to have an C<:Init> subroutine! All the
work will be taken care of for you.

=item Parameter Preprocessing

You can specify a subroutine for a parameter that will be called on that
parameter prior to any of the other parameter actions described above being
taken:

 package My::Class; {
     use Object::InsideOut;

     my @data :Field;

     my %init_args :InitArgs = (
         'DATA' => {
             'Preprocess' => \&my_preproc,
             'Field'      => \@data,
             'Type'       => 'Numeric',
             'Default'    => 99,
         },
     );

     sub my_preproc
     {
         my ($class, $param, $spec, $obj, $value) = @_;

         # Preform parameter preprocessing
         ...

         # Return result
         return ...;
     }
 }

As the above illustrates, the parameter preprocessing subroutine is sent five
arguments:

=over

=item * The name of the class associated with the parameter

This would be C<My::Class> in the example above.

=item * The name of the parameter

This would be C<DATA> in the example above.

=item * A hash ref of the parameter's specifiers

The hash ref paired to the C<DATA> key in the C<:InitArgs> hash.

=item * The object being initialized

=item * The parameter's value

This is the value assigned to the parameter in the C<-E<gt>new()> method's
argument list.  If the parameter was not provided to C<-E<gt>new()>, then
C<undef> will sent.

=back

The return value of the preprocessing subroutine will then be assigned to the
parameter.

Be careful about what types of data the preprocessing subroutine tries to make
use of C<external> to the arguments supplied.  For instance, because the order
of parameter processing is not specified, the preprocessing subroutine cannot
rely on whether or not some other parameter is set.  Such processing would
need to be done in the C<:Init> subroutine.  It can, however, make use of
object data set by classes I<higher up> in the class hierarchy.  (That is why
the object is provided as one of the arguments.)

Possible uses for parameter preprocessing include:

=over

=item * Overriding the supplied value (or even deleting it by returning C<undef>)

=item * Providing a dynamically-determined default value

=back

=back

(In the above, I<Regex> may be I<Regexp> or just I<Re>, I<Default> may be
I<Defaults> or I<Def>, and I<Preprocess> may be I<Preproc> or I<Pre>.  They
and the other specifier keys are case-insensitive, as well.)

=head2 Object Pre-Initialization

Occassionally, a subclass may need to send a parameter to a parent class as
part of object initialization.  This can be accomplished by supplying a
C<:PreInit> labeled subroutine in the subclass.  These subroutines, if found,
are called in order from the bottom of the class heirarchy upwards.

The subroutine should expect two arguments:  The newly created
(un-initialized) object (i.e., C<$self>), and a hash ref of all the arguments
from the C<-E<gt>new()> method call, including any additional arguments added
by other C<:PreInit> subroutines.  The hash ref will not be exactly as
supplied to C<-E<gt>new()>, but will be I<flattened> into a single hash ref.
For example,

 my $obj = My::Class->new(
     'param_X' => 'value_X',
     {
         'param_A' => 'value_A',
         'param_B' => 'value_B',
     },
     'My::Class' => { 'param' => 'value' },
 );

would produce

 {
     'param_X' => 'value_X',
     'param_A' => 'value_A',
     'param_B' => 'value_B',
     'My::Class' => { 'param' => 'value' }
 }

as the hash ref to the C<:PreInit> subroutine.

The C<:PreInit> subroutine may then add, modify or even remove any parameters
from the hash ref as needed for its purposes.

=head2 Getting Data

In class code, data can be fetched directly from an object's field array
(hash) using the object's ID:

 $data = $field[$$self];
     # or
 $data = $field{$$self};

=head2 Setting Data

Object::InsideOut automatically exports a method called C<set> to each class.
This method should be used in class code to put data into object field
arrays/hashes whenever there is the possibility that the class code may be
used in an application that uses L<threads::shared>.

As mentioned above, data can be put directly into an object's field array
(hash) using the object's ID:

 $field[$$self] = $data;
     # or
 $field{$$self} = $data;

However, in a threaded application that uses data sharing (i.e., uses
C<threads::shared>), C<$data> must be converted into shared data so that it
can be put into the field array (hash).  The C<-E<gt>set()> method handles
all those details for you.

The C<-E<gt>set()> method, requires two arguments:  A reference to the object
field array/hash, and the data (as a scalar) to be put in it:

 $self->set(\@field, $data);
     # or
 $self->set(\%field, $data);

To be clear, the C<-E<gt>set()> method is used inside class code; not
application code.  Use it inside any object methods that set data in object
field arrays/hashes.

In the event of a method naming conflict, the C<-E<gt>set()> method can be
called using its fully-qualified name:

 $self->Object::InsideOut::set(\@field, $data);

=head2 Automatic Accessor Generation

As part of the L</"Field Declarations">, you can optionally specify the
automatic generation of accessor methods.

=over

=item Accessor Naming

You can specify the generation of a pair of I<standard-named> accessor methods
(i.e., prefixed by I<get_> and I<set_>):

 my @data :Field('Standard' => 'data');

The above results in Object::InsideOut automatically generating accessor
methods named C<get_data> and C<set_data>.  (The keyword C<Standard> is
case-insensitive, and can be abbreviated to C<Std>.)

You can also separately specify the I<get> and/or I<set> accessors:

 my @name :Field('Get' => 'name', 'Set' => 'change_name');
     # or
 my @name :Field('Get' => 'get_name');
     # or
 my @name :Field('Set' => 'new_name');

For the above, you specify the full name of the accessor(s) (i.e., no prefix
is added to the given name(s)).  (The C<Get> and C<Set> keywords are
case-insensitive.)

You can specify the automatic generation of a combined I<get/set> accessor
method:

 my @comment :Field('Accessor' => 'comment');

which would be used as follows:

 # Set a new comment
 $obj->comment("I have no comment, today.");

 # Get the current comment
 my $cmt = $obj->comment();

(The keyword C<Accessor> is case-insensitive, and can be abbreviated to
C<Acc> or can be specified as C<get_set> or C<Combined> or C<Combo> or
C<Mutator>.)

=item I<Set> Accessor Return Value

For any of the automatically generated methods that perform I<set> operations,
the default for the method's return value is the value being set (i.e., the
I<new> value).

The C<Return> keyword allows you to modify the default behavior.  The other
options are to have the I<set> accessor return the I<old> (previous) value (or
C<undef> if unset):

 my @data :Field('Set' => 'set_data', 'Return' => 'Old');

or to return the object itself:

 my @data :Field('Set' => 'set_data', 'Return' => 'Object');

Returning the object from a I<set> method allows it to be chained to other
methods:

 $obj->set_data($data)->do_something();

If desired, you can explicitly specify the default behavior of returning the
I<new> value:

 my @data :Field('Set' => 'set_data', 'Return' => 'New');

(C<Return> may be abbreviated to C<Ret>; C<Previous>, C<Prev> and C<Prior> are
synonymous with C<Old>; and C<Object> may be abbreviated to C<Obj> and is also
synonymous with C<Self>.  All these are case-insensitive.)

=item Accessor Type Checking

You may, optionally, direct Object::InsideOut to add type-checking code to the
I<set/combined> accessor:

 my @level :Field('Accessor' => 'level', 'Type' => 'Numeric');

Available types are:

=over

=item Numeric

Can also be specified as C<Num> or C<Number>.  This uses
Scalar::Util::looks_like_number to test the input value.

=item List or Array

This type permits the accessor to accept multiple values (that are then placed
in an array ref) or a single array ref.

=item Array_ref

This specifies that the accessor can only accept a single array reference.  Can
also be specified as C<Arrayref>.

=item Hash

This type allows multiple S<C<key =E<gt> value>> pairs (that are then placed in
a hash ref) or a single hash ref.

=item Hash_ref

This specifies that the accessor can only accept a single hash reference.  Can
also be specified as C<Hashref>.

=item A class name

The accessor will only accept a value of the specified class, or one of its
sub-classes (i.e., type checking is done using C<-E<gt>isa()>).  For example,
C<My::Class>.

=item Other reference type

The accessor will only accept a value of the specified reference type
(as returned by L<ref()|perlfunc/"ref EXPR">).  For example, C<CODE>.

=back

The types above are case-insensitive (e.g., 'NUMERIC', 'Numeric', 'numeric',
etc.), except for the last two.

The C<Type> keyword can also be paired with a code reference to provide custom
type checking.  The code ref can either be in the form of an anonymous
subroutine, or a fully-qualified subroutine name.  The result of executing the
code ref on the input argument should be a boolean value.

 package My::Class; {
     use Object::InsideOut;

     # For accessor type checking, the subroutine can be made 'Private'
     sub positive :Private {
         return (Scalar::Util::looks_like_number($_[0]) &&
                 ($_[0] > 0));
     }

     # Code ref is an anonymous subroutine
     # (This one checks that the argument is a SCALAR)
     my @data :Field('Accessor' => 'data', 'Type' => sub { ! ref($_[0]) } );

     # Code ref using a fully-qualified subroutine name
     my @num  :Field('Accessor' => 'num',  'Type' => \&My::Class::positive);
 }

Note that it is an error to use the C<Type> keyword by itself, or in
combination with only the C<Get> keyword.

Due to limitations in the Perl parser, you cannot use line wrapping with the
C<:Field> attribute:

 # This doesn't work
 # my @level :Field('Get'  => 'level',
 #                  'Set'  => 'set_level',
 #                  'Type' => 'Num');

 # Must be all on one line
 my @level :Field('Get' =>'level', 'Set' => 'set_level', 'Type' => 'Num');

=back

=head2 I<Weak> Fields

Frequently, it is useful to store L<weaken|Scalar::Util/"weaken REF">ed
references to data or objects in a field.  Such a field can be declared as
C<weak> so that data (i.e., references) set via automatically generated
accessors, C<:InitArgs>, the C<-E<gt>set()> method, etc., will automatically
be L<weaken|Scalar::Util/"weaken REF">ed after being stored in the field
array/hash.

 my @data :Field('Weak' => 1);

NOTE: If data in a I<weak> field is set directly (i.e., the C<-E<gt>set()>
method is not used), then L<weaken()|Scalar::Util/"weaken REF"> must be
invoked on the stored reference afterwards:

 $field[$$self] = $data;
 Scalar::Util::weaken($field[$$self]);

=head2 Field Cloning

Object cloning can be controlled at the field level such that only specified
fields are I<deep> copied when C<-E<gt>clone()> is called without any
arguments.  This is done by adding another specifier to the C<:Field>
attribute:

 my @data :Field('Clone' => 'deep');
    # or
 my @data :Field('Copy' => 'deep');
    # or
 my @data :Field('Deep' => 1);

As usual, the keywords above are case-insensitive.

=head2 Object ID

By default, the ID of an object is derived from a sequence counter for the
object's class hierarchy.  This should suffice for nearly all cases of class
development.  If there is a special need for the module code to control the
object ID (see L<Math::Random::MT::Auto> as an example), then an C<:ID>
labeled subroutine can be specified:

 sub _id :ID
 {
     my $class = $_[0];

     # Determine a unique object ID
     ...

     return ($id);
 }

The ID returned by your subroutine can be any kind of I<regular> scalar (e.g.,
a string or a number).  However, if the ID is something other than a
low-valued integer, then you will have to architect all your classes using
hashes for the object fields.

Within any class hierarchy only one class may specify an C<:ID> subroutine.

=head2 Object Replication

Object replication occurs explicitly when the C<-E<gt>clone()> method is called
on an object, and implicitly when threads are created in a threaded
application.  In nearly all cases, Object::InsideOut will take care of all the
details for you.

In rare cases, a class may require special handling for object replication.
It must then provide a subroutine labeled with the C<:Replicate> attribute.
This subroutine will be sent three arguments:  The parent and the cloned
objects, and a flag:

 sub _replicate :Replicate
 {
     my ($parent, $clone, $flag) = @_;

     # Special object replication processing
     if ($clone eq 'CLONE') {
        # Handling for thread cloning
        ...
     } elsif ($clone eq 'deep') {
        # Deep copy of the parent
        ...
     } else {
        # Shallow copying
        ...
     }
 }

In the case of thread cloning, C<$flag> will be set to C<'CLONE'>, and the
C<$parent> object is just an un-blessed anonymous scalar reference that
contains the ID for the object in the parent thread.

When invoked via the C<-E<gt>clone()> method, C<$flag> may be either an empty
string which denotes that a I<shallow> copy is being produced for the clone,
or C<$flag> may be set to C<'deep'> indicating a I<deep> copy is being
produced.

The C<:Replicate> subroutine only needs to deal with the special replication
processing needed by the object:  Object::InsideOut will handle all the other
details.

=head2 Object Destruction

Object::InsideOut exports a C<DESTROY> method to each class that deletes an
object's data from the object field arrays (hashes).  If a class requires
additional destruction processing (e.g., closing filehandles), then it must
provide a subroutine labeled with the C<:Destroy> attribute.  This subroutine
will be sent the object that is being destroyed:

 sub _destroy :Destroy
 {
     my $obj = $_[0];

     # Special object destruction processing
 }

The C<:Destroy> subroutine only needs to deal with the special destruction
processing:  The C<DESTROY> method will handle all the other details of object
destruction.

=head2 Cumulative Methods

Normally, methods with the same name in a class hierarchy are masked (i.e.,
overridden) by inheritance - only the method in the most-derived class is
called.  With cumulative methods, this masking is removed, and the same named
method is called in each of the classes within the hierarchy.  The return
results from each call (if any) are then gathered together into the return
value for the original method call.  For example,

 package My::Class; {
     use Object::InsideOut;

     sub what_am_i :Cumulative
     {
         my $self = shift;

         my $ima = (ref($self) eq __PACKAGE__)
                     ? q/I was created as a /
                     : q/My top class is /;

         return ($ima . __PACKAGE__);
     }
 }

 package My::Foo; {
     use Object::InsideOut 'My::Class';

      sub what_am_i :Cumulative
     {
         my $self = shift;

         my $ima = (ref($self) eq __PACKAGE__)
                     ? q/I was created as a /
                     : q/I'm also a /;

         return ($ima . __PACKAGE__);
     }
 }

 package My::Child; {
     use Object::InsideOut 'My::Foo';

      sub what_am_i :Cumulative
     {
         my $self = shift;

         my $ima = (ref($self) eq __PACKAGE__)
                     ? q/I was created as a /
                     : q/I'm in class /;

         return ($ima . __PACKAGE__);
     }
 }

 package main;

 my $obj = My::Child->new();
 my @desc = $obj->what_am_i();
 print(join("\n", @desc), "\n");

produces:

 My top class is My::Class
 I'm also a My::Foo
 I was created as a My::Child

When called in a list context (as in the above), the return results of
cumulative methods are accumulated, and returned as a list.

In a scalar context, a results object is returned that segregates the results
from the cumulative method calls by class.  Through overloading, this object
can then be dereferenced as an array, hash, string, number, or boolean.  For
example, the above could be rewritten as:

 my $obj = My::Child->new();
 my $desc = $obj->what_am_i();        # Results object
 print(join("\n", @{$desc}), "\n");   # Dereference as an array

The following uses hash dereferencing:

 my $obj = My::Child->new();
 my $desc = $obj->what_am_i();
 while (my ($class, $value) = each(%{$desc})) {
     print("Class $class reports:\n\t$value\n");
 }

and produces:

 Class My::Class reports:
         My top class is My::Class
 Class My::Child reports:
         I was created as a My::Child
 Class My::Foo reports:
         I'm also a My::Foo

As illustrated above, Cumulative methods are tagged with the C<:Cumulative>
attribute (or S<C<:Cumulative(top down)>>), and propagate from the I<top down>
through the class hierarchy (i.e., from the base classes down through the
child classes).  If tagged with S<C<:Cumulative(bottom up)>>, they will
propagated from the object's class upwards through the parent classes.

=head2 Chained Methods

In addition to C<:Cumulative>, Object::InsideOut provides a way of creating
methods that are chained together so that their return values are passed as
input arguments to other similarly named methods in the same class hierarchy.
In this way, the chained methods act as though they were I<piped> together.

For example, imagine you had a method called C<format_name> that formats some
text for display:

 package Subscriber; {
     use Object::InsideOut;

     sub format_name {
         my ($self, $name) = @_;

         # Strip leading and trailing whitespace
         $name =~ s/^\s+//;
         $name =~ s/\s+$//;

         return ($name);
     }
 }

And elsewhere you have a second class that formats the case of names:

 package Person; {
     use Lingua::EN::NameCase qw(nc);
     use Object::InsideOut;

     sub format_name {
         my ($self, $name) = @_;

         # Attempt to properly case names
         return (nc($name));
     }
 }

And you decide that you'd like to perform some formatting of your own, and
then have all the parent methods apply their own formatting.  Normally, if you
have a single parent class, you'd just call the method directly with
C<$self->SUPER::format_name($name)>, but if you have more than one parent
class you'd have to explicitly call each method directly:

 package Customer; {
     use Object::InsideOut qw(Person Subscriber);

     sub format_name {
         my ($self, $name) = @_;

         # Compress all whitespace into a single space
         $name =~ s/\s+/ /g;

         $name = $self->Subscriber::format_name($name);
         $name = $self->Person::format_name($name);

         return $name;
     }
 }

With Object::InsideOut you'd add the C<:Chained> attribute to each class's
C<format_name> method, and the methods will be chained together automatically:

 package Subscriber; {
     use Object::InsideOut;

     sub format_name :Chained {
         my ($self, $name) = @_;

         # Strip leading and trailing whitespace
         $name =~ s/^\s+//;
         $name =~ s/\s+$//;

         return ($name);
     }
 }

 package Person; {
     use Lingua::EN::NameCase qw(nc);
     use Object::InsideOut;

     sub format_name :Chained {
         my ($self, $name) = @_;

         # Attempt to properly case names
         return (nc($name));
     }
 }

 package Customer; {
     use Object::InsideOut qw(Person Subscriber);

     sub format_name :Chained {
         my ($self, $name) = @_;

         # Compress all whitespace into a single space
         $name =~ s/\s+/ /g;

         return ($name);
     }
 }

So passing in someone's name to C<format_name> in C<Customer> would cause
leading and trailing whitespace to be removed, then the name to be properly
cased, and finally whitespace to be compressed to a single space.  The
resulting C<$name> would be returned to the caller.

The default direction is to chain methods from the base classes at the top of
the class hierarchy down through the child classes.  You may use the attribute
S<C<:Chained(top down)>> to make this more explicit.

If you label the method with the S<C<:Chained(bottom up)>> attribute, then the
chained methods are called starting with the object's class and working
upwards through the class hierarchy, similar to how S<C<:Cumulative(bottom
up)>> works.

Unlike C<:Cumulative> methods, C<:Chained> methods return a scalar when used
in a scalar context; not a results object.

=head2 Automethods

There are significant issues related to Perl's C<AUTOLOAD> mechanism that
cause it to be ill-suited for use in a class hierarchy. Therefore,
Object::InsideOut implements its own C<:Automethod> mechanism to overcome
these problems.

Classes requiring C<AUTOLOAD>-type capabilities must provided a subroutine
labeled with the C<:Automethod> attribute.  The C<:Automethod> subroutine
will be called with the object and the arguments in the original method call
(the same as for C<AUTOLOAD>).  The C<:Automethod> subroutine should return
either a subroutine reference that implements the requested method's
functionality, or else C<undef> to indicate that it doesn't know how to handle
the request.

Using its own C<AUTOLOAD> subroutine (which is exported to every class),
Object::InsideOut walks through the class tree, calling each C<:Automethod>
subroutine, as needed, to fulfill an unimplemented method call.

The name of the method being called is passed as C<$_> instead of
C<$AUTOLOAD>, and does I<not> have the class name prepended to it.  If the
C<:Automethod> subroutine also needs to access the C<$_> from the caller's
scope, it is available as C<$CALLER::_>.

Automethods can also be made to act as L</"Cumulative Methods"> or L</"Chained
Methods">.  In these cases, the C<:Automethod> subroutine should return two
values: The subroutine ref to handle the method call, and a string designating
the type of method.  The designator has the same form as the attributes used
to designate C<:Cumulative> and C<:Chained> methods:

 ':Cumulative'  or  ':Cumulative(top down)'
 ':Cumulative(bottom up)'
 ':Chained'     or  ':Chained(top down)'
 ':Chained(bottom up)'

The following skeletal code illustrates how an C<:Automethod> subroutine could
be structured:

 sub _automethod :Automethod
 {
     my $self = shift;
     my @args = @_;

     my $method_name = $_;

     # This class can handle the method directly
     if (...) {
         my $handler = sub {
             my $self = shift;
             ...
             return ...;
         };

         ### OPTIONAL ###
         # Install the handler so it gets called directly next time
         # no strict refs;
         # *{__PACKAGE__.'::'.$method_name} = $handler;
         ################

         return ($handler);
     }

     # This class can handle the method as part of a chain
     if (...) {
         my $chained_handler = sub {
             my $self = shift;
             ...
             return ...;
         };

         return ($chained_handler, ':Chained');
     }

     # This class cannot handle the method request
     return;
 }

Note: The I<OPTIONAL> code above for installing the generated handler as a
method should not be used with C<:Cumulative> or C<:Chained> Automethods.

=head2 Object Serialization

=over

=item my $array_ref = $obj->dump();

=item my $string = $obj->dump(1);

Object::InsideOut exports a method called C<dump> to each class that returns
either a I<Perl> or a string representation of the object that invokes the
method.

The I<Perl> representation is returned when C<-E<gt>dump()> is called without
arguments.  It consists of an array ref whose first element is the name of the
object's class, and whose second element is a hash ref containing the object's
data.  The object data hash ref contains keys for each of the classes that make
up the object's hierarchy. The values for those keys are hash refs containing
S<C<key =E<gt> value>> pairs for the object's fields.  For example:

 [
   'My::Class::Sub',
   {
     'My::Class' => {
                      'data' => 'value'
                    },
     'My::Class::Sub' => {
                           'life' => 42
                         }
   }
 ]

The name for an object field (I<data> and I<life> in the example above) can be
specified as part of the L<field declaration|/"Field Declarations"> using the
C<NAME> keyword:

 my @life :Field('Name' => 'life');

If the C<NAME> keyword is not present, then the name for a field will be
either the tag from the C<:InitArgs> array that is associated with the field,
its I<get> method name, its I<set> method name, or, failing all that, a string
of the form C<ARRAY(0x...)> or C<HASH(0x...)>.

When called with a I<true> argument, C<-E<gt>dump()> returns a string version
of the I<Perl> representation using L<Data::Dumper>.

Note that using L<Data::Dumper> directly on an inside-out object will not
produce the desired results (it'll just output the contents of the scalar
ref).  Also, if inside-out objects are stored inside other structures, a dump
of those structures will not contain the contents of the object's fields.

In the event of a method naming conflict, the C<-E<gt>dump()> method can be
called using its fully-qualified name:

 my $dump = $obj->Object::InsideOut::dump();

=item my $obj = Object::InsideOut->pump($data);

C<Object::InsideOut-E<gt>pump()> takes the output from the C<-E<gt>dump()>
method, and returns an object that is created using that data.  If C<$data> is
the array ref returned by using C<$obj-E<gt>dump()>, then the data is inserted
directly into the corresponding fields for each class in the object's class
hierarchy.  If C<$data> is the string returned by using C<$obj-E<gt>dump(1)>,
then it is C<eval>ed to turn it into an array ref, and then processed as
above.

If any of an object's fields are dumped to field name keys of the form
C<ARRAY(0x...)> or C<HASH(0x...)> (see above), then the data will not be
reloadable using C<Object::InsideOut-E<gt>pump()>.  To overcome this problem,
the class developer must either add C<Name> keywords to the C<:Field>
declarations (see above), or provide a C<:Dumper>/C<:Pumper> pair of
subroutines as described below.

=item C<:Dumper> Subroutine Attribute

If a class requires special processing to dump its data, then it can provide a
subroutine labeled with the C<:Dumper> attribute.  This subroutine will be
sent the object that is being dumped.  It may then return any type of scalar
the developer deems appropriate.  Most likely this would be a hash ref
containing S<C<key =E<gt> value>> pairs for the object's fields.  For example,

 my @data :Field;

 sub _dump :Dumper
 {
     my $obj = $_[0];

     my %field_data;
     $field_data{'data'} = $data[$$obj];

     return (\%field_data);
 }

Just be sure not to call your C<:Dumper> subroutine C<dump> as that is the
name of the dump method exported by Object::InsideOut as explained above.

=item C<:Pumper> Subroutine Attribute

If a class supplies a C<:Dumper> subroutine, it will most likely need to
provide a complementary C<:Pumper> labeled subroutine that will be used as
part of creating an object from dumped data using
C<Object::InsideOut::pump()>.  The subroutine will be supplied the new object
that is being created, and whatever scalar was returned by the C<:Dumper>
subroutine.  The corresponding C<:Pumper> for the example C<:Dumper> above
would be:

 sub _pump :Pumper
 {
     my ($obj, $field_data) = @_;

     $data[$$obj] = $field_data->{'data'};
 }

=item Storable

Object::InsideOut also supports object serialization using the L<Storable>
module.  There are two methods for specifying that a class can be serialized
using L<Storable>.  The first method involves adding L<Storable> to the
Object::InsideOut declaration in your package:

 package My::Class; {
     use Object::InsideOut qw(Storable);
     ...
 }

and adding C<use Storable;> in your application.  Then you can use the
C<-E<gt>store()> and C<-E<gt>freeze()> methods to serialize your objects, and
the C<retrieve()> and C<thaw()> subroutines to deserialize them.

 package main;
 use Storable;
 use My::Class;

 my $obj = My::Class->new(...);
 $obj->store('/tmp/object.dat');
 ...
 my $obj2 = retrieve('/tmp/object.dat');

The other method of specifying L<Storable> serialization involves setting a
C<::storable> variable (inside a C<BEGIN> block) for the class prior to its
use:

 package main;
 use Storable;

 BEGIN {
     $My::Class::storable = 1;
 }
 use My::Class;

=back

=head2 Dynamic Field Creation

Normally, object fields are declared as part of the class code.  However,
some classes may need the capability to create object fields I<on-the-fly>,
for example, as part of an C<:Automethod>.  Object::InsideOut provides a class
method for this:

 # Dynamically create a hash field with standard accessors
 Object::InsideOut->create_field($class, '%'.$fld, "'Standard'=>'$fld'");

The first argument is the class to which the field will be added.  The second
argument is a string containing the name of the field preceeded by either a
C<@> or C<%> to declare an array field or hash field, respectively.  The third
argument is a string containing S<C<key =E<gt> value>> pairs used in
conjunction with the C<:Field> attribute for generating field accessors.

Here's a more elaborate example used in inside an C<:Automethod>:

 package My::Class; {
     use Object::InsideOut;

     sub auto :Automethod
     {
         my $self = $_[0];
         my $class = ref($self) || $self;
         my $method = $_;

         # Extract desired field name from get_/set_ method name
         my ($fld_name) = $method =~ /^[gs]et_(.*)$/;
         if (! $fld_name) {
             return;    # Not a recognized method
         }

         # Create the field and its standard accessors
         Object::InsideOut->create_field($class, '@'.$fld_name,
                                         "'Standard'=>'$fld_name'");

         # Return code ref for newly created accessor
         no strict 'refs';
         return *{$class.'::'.$method}{'CODE'};
     }
 }

=head2 Restricted and Private Methods

Access to certain methods can be narrowed by use of the C<:Restricted> and
C<:Private> attributes.  C<:Restricted> methods can only be called from within
the class's hierarchy.  C<:Private> methods can only be called from within the
method's class.

Without the above attributes, most methods have I<public> access.  If desired,
you may explicitly label them with the C<:Public> attribute.

You can also specify access permissions on L<automatically generated
accessors|/"Automatic Accessor Generation">:

 my @data     :Field('Standard' => 'data', 'Permission' => 'private');
 my @info     :Field('Set' => 'set_info',  'Perm'       => 'restricted');
 my @internal :Field('Acc' => 'internal',  'Private'    => 1);
 my @state    :Field('Get' => 'state',     'Restricted' => 1);

Such permissions apply to both of the I<get> and I<set> accessors created on a
field.  If different permissions are required on an accessor pair, then you'll
have to create the accessors yourself, using the C<:Restricted> and
C<:Private> attributes when applicable:

 # Create a private set method on the 'foo' field
 my @foo :Field('Set' => 'set_foo', 'Priv' => 1);

 # Read access on the 'foo' field is restricted
 sub get_foo :Restrict
 {
     return ($foo[${$_[0]}]);
 }

 # Create a restricted set method on the 'bar' field
 my %bar :Field('Set' => 'set_bar', 'Perm' => 'restrict');

 # Read access on the 'foo' field is public
 sub get_bar
 {
     return ($bar{${$_[0]}});
 }

=head2 Hidden Methods

For subroutines marked with the following attributes:

=over

=item :ID

=item :Init

=item :Replicate

=item :Destroy

=item :Automethod

=item :Dumper

=item :Pumper

=back

Object::InsideOut normally renders them uncallable (hidden) to class and
application code (as they should normally only be needed by Object::InsideOut
itself).  If needed, this behavior can be overridden by adding the C<PUBLIC>,
C<RESTRICTED> or C<PRIVATE> keywords following the attribute:

 sub _init :Init(private)    # Callable from within this class
 {
     my ($self, $args) = @_;

     ...
 }

NOTE:  A bug in Perl 5.6.0 prevents using these access keywords.  As such,
subroutines marked with the above attributes will be left with I<public>
access.

NOTE:  The above cannot be accomplished by using the corresponding attributes.
For example:

 # sub _init :Init :Private    # Wrong syntax - doesn't work

=head2 Object Coercion

Object::InsideOut provides support for various forms of object coercion
through the L<overload> mechanism.  For instance, if you want an object to be
usable directly in a string, you would supply a subroutine in your class
labeled with the C<:Stringify> attribute:

 sub as_string :Stringify
 {
     my $self = $_[0];
     my $string = ...;
     return ($string);
 }

Then you could do things like:

 print("The object says, '$obj'\n");

For a boolean context, you would supply:

 sub as_bool :Boolify
 {
     my $self = $_[0];
     my $true_or_false = ...;
     return ($true_or_false);
 }

and use it in this manner:

 if (! defined($obj)) {
     # The object is undefined
     ....

 } elsif (! $obj) {
     # The object returned a false value
     ...
 }

The following coercion attributes are supported:

=over

=item :Stringify

=item :Numerify

=item :Boolify

=item :Arrayify

=item :Hashify

=item :Globify

=item :Codify

=back

Coercing an object to a scalar (C<:Scalarify>) is not supported as C<$$obj> is
the ID of the object and cannot be overridden.

=head1 FOREIGN CLASS INHERITANCE

Object::InsideOut supports inheritance from foreign (i.e.,
non-Object::InsideOut) classes.  This means that your classes can inherit from
other Perl class, and access their methods from your own objects.

One method of declaring foreign class inheritance is to add the class name to
the Object::InsideOut declaration inside your package:

 package My::Class; {
     use Object::InsideOut qw(Foreign::Class);
     ...
 }

This allows you to access the foreign class's static (i.e., class) methods from
your own class.  For example, suppose C<Foreign::Class> has a class method
called C<foo>.  With the above, you can access that method using
C<My::Class-E<gt>foo()> instead.

Multiple foreign inheritance is supported, as well:

 package My::Class; {
     use Object::InsideOut qw(Foreign::Class Other::Foreign::Class);
     ...
 }

=over

=item $self->inherit($obj, ...);

To use object methods from foreign classes, an object must I<inherit> from an
object of that class.  This would normally be done inside a class's C<:Init>
subroutine:

 package My::Class; {
     use Object::InsideOut qw(Foreign::Class);

     sub init :Init
     {
         my ($self, $args) = @_;

         my $foreign_obj = Foreign::Class->new(...);
         $self->inherit($foreign_obj);
     }
 }

Thus, with the above, if C<Foreign::Class> has an object method called C<bar>,
you can call that method from your own objects:

 package main;

 my $obj = My::Class->new();
 $obj->bar();

Object::InsideOut's C<AUTOLOAD> subroutine handles the dispatching of the
C<-E<gt>bar()> method call using the internally held inherited object (in this
case, C<$foreign_obj>).

Multiple inheritance is supported, as well:  You can call the
C<-E<gt>inherit()> method multiple times, or make just one call with all the
objects to be inherited from.

C<-E<gt>inherit()> is a restricted method.  In other words, you cannot use it
on an object outside of code belonging to the object's class tree (e.g., you
can't call it from application code).

In the event of a method naming conflict, the C<-E<gt>inherit()> method can be
called using its fully-qualified name:

 $self->Object::InsideOut::inherit($obj);

=item my @objs = $self->heritage();

=item my $obj = $self->heritage($class);

=item my @objs = $self->heritage($class1, $class2, ...);

Your class code can retrieve any inherited objects using the
C<-E<gt>heritage()> method. When called without any arguments, it returns a
list of any objects that were stored by the calling class using the calling
object.  In other words, if class C<My::Class> uses object C<$obj> to store
foreign objects C<$fobj1> and C<$fobj2>, then later on in class C<My::Class>,
C<$obj-E<gt>heritage()> will return C<$fobj1> and C<$fobj2>.

C<-E<gt>heritage()> can also be called with one or more class name arguments.
In this case, only objects of the specified class(es) are returned.

In the event of a method naming conflict, the C<-E<gt>heritage()> method can
be called using its fully-qualified name:

 my @objs = $self->Object::InsideOut::heritage();

=item $self->disinherit($class [, ...])

=item $self->disinherit($obj [, ...])

The C<-E<gt>disinherit()> method disassociates (i.e., deletes) the inheritance
of foreign object(s) from an object.  The foreign objects may be specified by
class, or using the actual inherited object (retrieved via C<-E<gt>heritage()>,
for example).

The call is only effective when called inside the class code that established
the initial inheritance.  In other words, if an inheritance is set up inside a
class, then disinheritance can only be done from inside that class.

In the event of a method naming conflict, the C<-E<gt>disinherit()> method can
be called using its fully-qualified name:

 $self->Object::InsideOut::disinherit($obj [, ...])

=back

B<NOTE>:  With foreign inheritance, you only have access to class and object
methods.  The encapsulation of the inherited objects is strong, meaning that
only the class where the inheritance takes place has direct access to the
inherited object.  If access to the inherited objects themselves, or their
internal hash fields (in the case of I<blessed hash> objects), is needed
outside the class, then you'll need to write your own accessors for that.

B<LIMITATION>:  You cannot use fully-qualified method names to access foreign
methods (when encapsulated foreign objects are involved).  Thus, the following
will not work:

 my $obj = My::Class->new();
 $obj->Foreign::Class::bar();

Normally, you shouldn't ever need to do the above:  C<$obj-E<gt>bar()> would
suffice.

The only time this may be an issue is when the I<native> class I<overrides> an
inherited foreign class's method (e.g., C<My::Class> has its own
C<-E<gt>bar()> method).  Such overridden methods are not directly callable.
If such overriding is intentional, then this should not be an issue:  No one
should be writing code that tries to by-pass the override.  However, if the
overriding is accidently, then either the I<native> method should be renamed,
or the I<native> class should provide a wrapper method so that the
functionality of the overridden method is made available under a different
name.

=head2 C<use base> and Fully-qualified Method Names

The foreign inheritance methodology handled by the above is predicated on
non-Object::InsideOut classes that generate their own objects and expect their
object methods to be invoked via those objects.

There are exceptions to this rule:

=over

=item 1. Foreign object methods that expect to be invoked via the inheriting
class's object, or foreign object methods that don't care how they are invoked
(i.e., they don't make reference to the invoking object).

This is the case where a class provides auxiliary methods for your objects,
but from which you don't actually create any objects (i.e., there is no
corresponding foreign object, and C<$obj-E<gt>inherit($foreign)> is not used.)

In this case, you can either:

a. Declare the foreign class using the standard method (i.e., S<C<use
Object::InsideOut qw(Foreign::Class);>>), and invoke its methods using their
full path (e.g., C<$obj-E<gt>Foreign::Class::method();>); or

b. You can use the L<base> pragma so that you don't have to use the full path
for foreign methods.

 package My::Class; {
     use Object::InsideOut;
     use base 'Foreign::Class';
     ...
 }

The former scheme is faster.

=item 2. Foreign class methods that expect to be invoked via the inheriting
class.

As with the above, you can either invoke the class methods using their full
path (e.g., C<My::Class-E<gt>Foreign::Class::method();>), or you can C<use
base> so that you don't have to use the full path.  Again, using the full path
is faster.

L<Class::Singleton> is an example of this type of class.

=item 3. Class methods that don't care how they are invoked (i.e., they don't
make reference to the invoking class).

In this case, you can either use S<C<use Object::InsideOut
qw(Foreign::Class);>> for consistency, or use S<C<use base
qw(Foreign::Class);>> if (slightly) better performance is needed.

=back

If you're not familiar with the inner workings of the foreign class such that
you don't know if or which of the above exceptions applies, then the formulaic
approach would be to first use the documented method for foreign inheritance
(i.e., S<C<use Object::InsideOut qw(Foreign::Class);>>).  If that works, then
I strongly recommend that you just use that approach unless you have a good
reason not to.  If it doesn't work, then try C<use base>.


=head1 THREAD SUPPORT

For Perl 5.8.1 and later, this module fully supports L<threads> (i.e., is
thread safe), and supports the sharing of Object::InsideOut objects between
threads using L<threads::shared>.

To use Object::InsideOut in a threaded application, you must put S<C<use
threads;>> at the beginning of the application.  (The use of S<C<require
threads;>> after the program is running is not supported.)  If object sharing
is to be utilized, then S<C<use threads::shared;>> should follow.

If you just S<C<use threads;>>, then objects from one thread will be copied
and made available in a child thread.

The addition of S<C<use threads::shared;>> in and of itself does not alter the
behavior of Object::InsideOut objects.  The default behavior is to I<not>
share objects between threads (i.e., they act the same as with S<C<use
threads;>> alone).

To enable the sharing of objects between threads, you must specify which
classes will be involved with thread object sharing.  There are two methods
for doing this.  The first involves setting a C<::shared> variable (inside
a C<BEGIN> block) for the class prior to its use:

 use threads;
 use threads::shared;

 BEGIN {
     $My::Class::shared = 1;
 }
 use My::Class;

The other method is for a class to add a C<:SHARED> flag to its S<C<use
Object::InsideOut ...>> declaration:

 package My::Class; {
     use Object::InsideOut ':SHARED';
     ...
 }

When either sharing flag is set for one class in an object hierarchy, then all
the classes in the hierarchy are affected.

If a class cannot support thread object sharing (e.g., one of the object
fields contains code refs [which Perl cannot share between threads]), it
should specifically declare this fact:

 package My::Class; {
     use Object::InsideOut ':NOT_SHARED';
     ...
 }

However, you cannot mix thread object sharing classes with non-sharing
classes in the same class hierarchy:

 use threads;
 use threads::shared;

 package My::Class; {
     use Object::InsideOut ':SHARED';
     ...
 }

 package Other::Class; {
     use Object::InsideOut ':NOT_SHARED';
     ...
 }

 package My::Derived; {
     use Object::InsideOut qw(My::Class Other::Class);   # ERROR!
     ...
 }

Here is a complete example with thread object sharing enabled:

 use threads;
 use threads::shared;

 package My::Class; {
     use Object::InsideOut ':SHARED';

     # One list-type field
     my @data :Field('Accessor' => 'data', 'Type' => 'List');
 }

 package main;

 # New object
 my $obj = My::Class->new();

 # Set the object's 'data' field
 $obj->data(qw(foo bar baz));

 # Print out the object's data
 print(join(', ', @{$obj->data()}), "\n");       # "foo, bar, baz"

 # Create a thread and manipulate the object's data
 my $rc = threads->create(
         sub {
             # Read the object's data
             my $data = $obj->data();
             # Print out the object's data
             print(join(', ', @{$data}), "\n");  # "foo, bar, baz"
             # Change the object's data
             $obj->data(@$data[1..2], 'zooks');
             # Print out the object's modified data
             print(join(', ', @{$obj->data()}), "\n");  # "bar, baz, zooks"
             return (1);
         }
     )->join();

 # Show that changes in the object are visible in the parent thread
 # I.e., this shows that the object was indeed shared between threads
 print(join(', ', @{$obj->data()}), "\n");       # "bar, baz, zooks"

=head1 SPECIAL USAGE

=head2 Usage With C<Exporter>

It is possible to use L<Exporter> to export functions from one inside-out
object class to another:

 use strict;
 use warnings;

 package Foo; {
     use Object::InsideOut 'Exporter';
     BEGIN {
         our @EXPORT_OK = qw(foo_name);
     }

     sub foo_name
     {
         return (__PACKAGE__);
     }
 }

 package Bar; {
     use Object::InsideOut 'Foo' => [ qw(foo_name) ];

     sub get_foo_name
     {
         return (foo_name());
     }
 }

 package main;

 print("Bar got Foo's name as '", Bar::get_foo_name(), "'\n");

Note that the C<BEGIN> block is needed to ensure that the L<Exporter> symbol
arrays (in this case C<@EXPORT_OK>) get populated properly.

=head2 Usage With C<require> and C<mod_perl>

Object::InsideOut usage under L<mod_perl> and with runtime-loaded classes is
supported automatically; no special coding is required.

=head2 Singleton Classes

A singleton class is a case where you would provide your own C<-E<gt>new()>
method that in turn calls Object::InsideOut's C<-E<gt>new()> method:

 package My::Class; {
     use Object::InsideOut;

     my $singleton;

     sub new {
         my $thing = shift;
         if (! $singleton) {
             $singleton = $thing->Object::InsideOut::new(@_);
         }
         return ($singleton);
     }
 }

=head1 DIAGNOSTICS

This module uses C<Exception::Class> for reporting errors.  The base error
class for this module is C<OIO>.  Here is an example of the basic manner for
trapping and handling errors:

 my $obj;
 eval { $obj = My::Class->new(); };
 if (my $e = OIO->caught()) {
     print(STDERR "Failure creating object: $e\n");
     exit(1);
 }

I have tried to make the messages and information returned by the error
objects as informative as possible.  Suggested improvements are welcome.
Also, please bring to my attention any conditions that you encounter where an
error occurs as a result of Object::InsideOut code that doesn't generate an
Exception::Class object.  Here is one such error:

=over

=item Invalid ARRAY/HASH attribute

This error indicates you forgot the following in your class's code:

 use Object::InsideOut qw(Parent::Class ...);

=back

=head1 BUGS AND LIMITATIONS

You cannot overload an object to a scalar context (i.e., can't C<:SCALARIFY>).

You cannot use two instances of the same class with mixed thread object
sharing in same application.

Cannot use attributes on I<subroutine stubs> (i.e., forward declaration
without later definition) with C<:Automethod>:

 package My::Class; {
     sub method :Private;   # Will not work

     sub _automethod :Automethod
     {
         # Code to handle call to 'method' stub
     }
 }

Due to limitations in the Perl parser, you cannot use line wrapping with the
C<:Field> attribute.

If a I<set> accessor accepts scalars, then you can store any inside-out
object type in it.  If its C<Type> is set to C<HASH>, then it can store any
I<blessed hash> object.

It is possible to I<hack together> a I<fake> Object::InsideOut object, and so
gain access to another object's data:

 my $fake = bless(\do{my $scalar}, 'Some::Class');
 $$fake = 86;   # ID of another object
 my $stolen = $fake->get_data();

Why anyone would try to do this is unknown.  How this could be used for any
sort of malicious exploitation is also unknown.  However, if preventing this
sort of I<security> issue a requirement, then do not use Object::InsideOut.

Returning objects from threads does not work:

 my $obj = threads->create(sub { return (Foo->new()); })->join();  # BAD

Instead, use thread object sharing, create the object before launching the
thread, and then manipulate the object inside the thread:

 my $obj = Foo->new();   # Class 'Foo' is set ':SHARED'
 threads->create(sub { $obj->set_data('bar'); })->join();
 my $data = $obj->get_data();

There are bugs associated with L<threads::shared> that may prevent you from
using foreign inheritance with shared objects, or storing objects inside of
shared objects.

For Perl 5.6.0 through 5.8.0, a Perl bug prevents package variables (e.g.,
object attribute arrays/hashes) from being referenced properly from subroutine
refs returned by an C<:Automethod> subroutine.  For Perl 5.8.0 there is no
workaround:  This bug causes Perl to core dump.  For Perl 5.6.0 through 5.6.2,
the workaround is to create a ref to the required variable inside the
C<:Automethod> subroutine, and use that inside the subroutine ref:

 package My::Class; {
     use Object::InsideOut;

     my %data;

     sub auto :Automethod
     {
         my $self = $_[0];
         my $name = $_;

         my $data = \%data;      # Workaround for 5.6.X bug

         return sub {
                     my $self = shift;
                     if (! @_) {
                         return ($$data{$name});
                     }
                     $$data{$name} = shift;
                };
     }
 }

For Perl 5.8.1 through 5.8.4, a Perl bug produces spurious warning messages
when threads are destroyed.  These messages are innocuous, and can be
suppressed by adding the following to your application code:

 $SIG{__WARN__} = sub {
         if ($_[0] !~ /^Attempt to free unreferenced scalar/) {
             print(STDERR @_);
         }
     };

A better solution would be to upgrade L<threads> and L<threads::shared> from
CPAN, especially if you encounter other problems associated with threads.

For Perl 5.8.4 and 5.8.5, the L</"Storable"> feature does not work due to a
Perl bug.  Use Object::InsideOut v1.33 if needed.

View existing bug reports at, and submit any new bugs, problems, patches, etc.
to: L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Object-InsideOut>

=head1 REQUIREMENTS

Perl 5.6.0 or later

L<Exception::Class> v1.22 or later

L<Scalar::Util> v1.10 or later.  It is possible to install a I<pure perl>
version of Scalar::Util, however, it will be missing the
L<weaken()|Scalar::Util/"weaken REF"> function which is needed by
Object::InsideOut.  You'll need to upgrade your version of Scalar::Util to one
that supports its C<XS> code.

L<Test::More> v0.50 or later (for installation)

=head1 SEE ALSO

Object::InsideOut Discussion Forum on CPAN:
L<http://www.cpanforum.com/dist/Object-InsideOut>

Annotated POD for Object::InsideOut:
L<http://annocpan.org/~JDHEDDEN/Object-InsideOut-1.45/lib/Object/InsideOut.pm>

Inside-out Object Model:
L<http://www.perlmonks.org/?node_id=219378>,
L<http://www.perlmonks.org/?node_id=483162>,
L<http://www.perlmonks.org/?node_id=515650>,
Chapters 15 and 16 of I<Perl Best Practices> by Damian Conway

L<Storable>

=head1 ACKNOWLEDGEMENTS

Abigail S<E<lt>perl AT abigail DOT nlE<gt>> for inside-out objects in general.

Damian Conway S<E<lt>dconway AT cpan DOT orgE<gt>> for L<Class::Std>.

David A. Golden S<E<lt>dagolden AT cpan DOT orgE<gt>> for thread handling for
inside-out objects.

Dan Kubb S<E<lt>dan.kubb-cpan AT autopilotmarketing DOT comE<gt>> for
C<:Chained> methods.

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2005, 2006 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
