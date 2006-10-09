package Object::InsideOut; {

require 5.006;

use strict;
use warnings;

our $VERSION = 2.06;

use Object::InsideOut::Exception 2.06;
use Object::InsideOut::Util 2.06 qw(create_object hash_re is_it make_shared);

use B;
use Scalar::Util 1.10;

{
    no warnings 'void';
    BEGIN {
        # Verify we have 'weaken'
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

# Cached value of original isa/can methods
my $UNIV_ISA = \&UNIVERSAL::isa;
my $UNIV_CAN = \&UNIVERSAL::can;

# Our own versions of ->isa() and ->can() that supports metadata
{
    no warnings 'redefine';

    *UNIVERSAL::isa = sub
    {
        my ($thing, $type) = @_;

        # Want classes?
        if (! $type) {
            return $thing->Object::InsideOut::meta()->get_classes();
        }

        goto $UNIV_ISA;
    };

    *UNIVERSAL::can = sub
    {
        my ($thing, $method) = @_;

        # Want methods?
        if (! $method) {
            my $meths = $thing->Object::InsideOut::meta()->get_methods();
            return (wantarray()) ? (keys(%$meths)) : [ keys(%$meths) ];
        }

        goto $UNIV_CAN;
    };
}

# ID of currently executing thread
my $THREAD_ID = 0;

# Contains flags as to whether or not a class is sharing objects between
# threads
my %IS_SHARING;

# Contains flags for classes that must only use hashes for fields
my %HASH_ONLY;

# Workaround for Perl's "in cleanup" bug
my $TERMINATING = 0;
END {
    $TERMINATING = 1;
}


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

        # Handle hash fields only flag
        if ($pkg =~ /^:HASH/i) {
            $HASH_ONLY{$class} = [ $class, (caller())[1,2] ];
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
            # Add parent to inherited classes
            $HERITAGE{$class}[1]{$parent} = undef;
        }
    }

    # Add Object::InsideOut to class's @ISA array, if needed
    if ($need_oio) {
        push(@{$class.'::ISA'}, __PACKAGE__);
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

# Fields that require type checking
my (%FIELD_TYPE, @FIELD_TYPE_INFO);

# Fields that require deep cloning
my (%DEEP_CLONE, @DEEP_CLONERS);

# Fields that store weakened refs
my (%WEAK, @WEAKEN);

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

# Methods that want merged args.  They are marked with an attribute called
# 'MergeArgs'.
my %ARG_WRAP;

# Methods that are support overloading capabilities for objects.
my %OVERLOAD;

# These are the attributes for designating 'overload' methods.
my @OVERLOAD_ATTRS = qw(STRINGIFY NUMERIFY BOOLIFY
                        ARRAYIFY HASHIFY GLOBIFY CODIFY);

# Allow class-specific attribute handlers.  These are 'chained' together from
# the bottom up.  They are :HIDDEN.
my %ATTR_HANDLERS;

# Metadata
my (%SUBROUTINES, %METHODS);

use Object::InsideOut::Metadata 2.03;

add_meta(__PACKAGE__, {
    'import'                 => {'hidden' => 1},
    'MODIFY_CODE_ATTRIBUTES' => {'hidden' => 1},
    'inherit'                => {'restricted' => 1},
    'disinherit'             => {'restricted' => 1},
    'heritage'               => {'restricted' => 1},
});


# Handles subroutine attributes supported by this package.
# See 'perldoc attributes' for details.
sub MODIFY_CODE_ATTRIBUTES
{
    my ($pkg, $code, @attrs) = @_;

    # Call attribute handlers in the class tree
    if (exists($ATTR_HANDLERS{'MOD'}{'CODE'})) {
        @attrs = CHECK_ATTRS('CODE', $pkg, $code, @attrs);
        return if (! @attrs);
    }

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
            push(@attrs, $arg) if $] > 5.006;
            $DO_INIT = 1;

        } elsif ($attr eq 'PREINIT') {
            $PREINITORS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr eq 'INIT') {
            $INITORS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^REPL(?:ICATE)?$/) {
            $REPLICATORS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^DEST(?:ROY)?$/) {
            $DESTROYERS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^AUTO(?:METHOD)?$/) {
            $AUTOMETHODS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;
            $DO_INIT = 1;

        } elsif ($attr =~ /^CUM(?:ULATIVE)?$/) {
            if ($arg =~ /BOTTOM\s+UP/) {
                push(@{$ANTICUMULATIVE{$pkg}}, $info);
            } else {
                push(@{$CUMULATIVE{$pkg}}, $info);
            }
            $DO_INIT = 1;

        } elsif ($attr =~ /^CHAIN(?:ED)?$/) {
            if ($arg =~ /BOTTOM\s+UP/) {
                push(@{$ANTICHAINED{$pkg}}, $info);
            } else {
                push(@{$CHAINED{$pkg}}, $info);
            }
            $DO_INIT = 1;

        } elsif ($attr =~ /^DUMP(?:ER)?$/) {
            $DUMPERS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^PUMP(?:ER)?$/) {
            $PUMPERS{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^RESTRICT(?:ED)?$/) {
            push(@{$RESTRICTED{$pkg}}, $info);
            $DO_INIT = 1;

        } elsif ($attr =~ /^PRIV(?:ATE)?$/) {
            push(@{$PRIVATE{$pkg}}, $info);
            $DO_INIT = 1;

        } elsif ($attr =~ /^HIDD?EN?$/) {
            push(@{$HIDDEN{$pkg}}, $info);
            $DO_INIT = 1;

        } elsif ($attr =~ /^SUB/) {
            push(@{$SUBROUTINES{$pkg}}, $info);
            if ($arg ne 'HIDDEN') {
                push(@attrs, $arg) if $] > 5.006;
            }
            $DO_INIT = 1;

        } elsif ($attr =~ /^METHOD/) {
            if ($arg ne 'HIDDEN') {
                push(@$info, $arg);
                push(@{$METHODS{$pkg}}, $info);
                $DO_INIT = 1;
            }

        } elsif ($attr =~ /^MERGE/) {
            push(@{$ARG_WRAP{$pkg}}, $info);
            if ($arg ne 'HIDDEN') {
                push(@attrs, $arg) if $] > 5.006;
            }
            $DO_INIT = 1;

        } elsif ($attr =~ /^MOD(?:IFY)?_(ARRAY|CODE|HASH|SCALAR)_ATTR/) {
            install_ATTRIBUTES();
            $ATTR_HANDLERS{'MOD'}{$1}{$pkg} = $code;
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr =~ /^FETCH_(ARRAY|CODE|HASH|SCALAR)_ATTR/) {
            install_ATTRIBUTES();
            push(@{$ATTR_HANDLERS{'FETCH'}{$1}}, $code);
            push(@attrs, $arg) if $] > 5.006;

        } elsif ($attr eq 'SCALARIFY') {
            OIO::Attribute->die(
                'message' => q/:SCALARIFY not allowed/,
                'Info'    => q/The scalar of an object is its object ID, and can't be redefined/,
                'ignore_package' => 'attributes');

        } elsif (my ($ify_attr) = grep { $_ eq $attr } @OVERLOAD_ATTRS) {
            # Overload (-ify) attributes
            push(@{$OVERLOAD{$pkg}}, [$ify_attr, @{$info} ]);
            $DO_INIT = 1;

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


# This subroutine handles attributes on hashes as part of this package.
# See 'perldoc attributes' for details.
sub MODIFY_HASH_ATTRIBUTES :Sub
{
    my ($pkg, $hash, @attrs) = @_;

    # Call attribute handlers in the class tree
    if (exists($ATTR_HANDLERS{'MOD'}{'HASH'})) {
        @attrs = CHECK_ATTRS('HASH', $pkg, $hash, @attrs);
        return if (! @attrs);
    }

    my @unused_attrs;   # List of any unhandled attributes

    # Process attributes
    foreach my $attr (@attrs) {
        # Declaration for object field hash
        if ($attr =~ /^(?:Field|[GS]et|Acc|Com|Mut|St(?:an)?d|LV(alue)?|All|Arg|Type)/i) {
            # Save save hash ref and attribute
            # Accessors will be build during initialization
            if ($attr =~ /^(?:Field|Type)/i) {
                unshift(@{$NEW_FIELDS{$pkg}}, [ $hash, $attr ]);
            } else {
                push(@{$NEW_FIELDS{$pkg}}, [ $hash, $attr ]);
            }
            $DO_INIT = 1;   # Flag that initialization is required
        }

        # Weak field
        elsif ($attr =~ /^Weak$/i) {
            $WEAK{$hash} = 1;
            push(@WEAKEN, $hash);
        }

        # Deep cloning field
        elsif ($attr =~ /^Deep$/i) {
            $DEEP_CLONE{$hash} = 1;
            push(@DEEP_CLONERS, $hash);
        }

        # Field name for dump
        elsif ($attr =~ /^Name\s*[(]\s*'?([^)'\s]+)'?\s*[)]/i) {
            $DUMP_FIELDS{$pkg}{$1} = [ $hash, 'Name' ];
        }

        # Declaration for object initializer hash
        elsif ($attr =~ /^InitArgs?$/i) {
            $INIT_ARGS{$pkg} = $hash;
            push(@DUMP_INITARGS, $pkg);
        }

        # Unhandled
        # (Must filter out ':shared' attribute due to Perl bug)
        elsif ($attr ne 'shared') {
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
sub MODIFY_ARRAY_ATTRIBUTES :Sub
{
    my ($pkg, $array, @attrs) = @_;

    # Call attribute handlers in the class tree
    if (exists($ATTR_HANDLERS{'MOD'}{'ARRAY'})) {
        @attrs = CHECK_ATTRS('ARRAY', $pkg, $array, @attrs);
        return if (! @attrs);
    }

    my @unused_attrs;   # List of any unhandled attributes

    # Process attributes
    foreach my $attr (@attrs) {
        # Declaration for object field array
        if ($attr =~ /^(?:Field|[GS]et|Acc|Com|Mut|St(?:an)?d|LV(alue)?|All|Arg|Type)/i) {
            # Save save array ref and attribute
            # Accessors will be build during initialization
            if ($attr =~ /^(?:Field|Type)/i) {
                unshift(@{$NEW_FIELDS{$pkg}}, [ $array, $attr ]);
            } else {
                push(@{$NEW_FIELDS{$pkg}}, [ $array, $attr ]);
            }
            $DO_INIT = 1;   # Flag that initialization is required
        }

        # Weak field
        elsif ($attr =~ /^Weak$/i) {
            $WEAK{$array} = 1;
            push(@WEAKEN, $array);
        }

        # Deep cloning field
        elsif ($attr =~ /^Deep$/i) {
            $DEEP_CLONE{$array} = 1;
            push(@DEEP_CLONERS, $array);
        }

        # Field name for dump
        elsif ($attr =~ /^Name\s*[(]\s*'?([^)'\s]+)'?\s*[)]/i) {
            $DUMP_FIELDS{$pkg}{$1} = [ $array, 'Name' ];
        }

        # Unhandled
        # (Must filter out ':shared' attribute due to Perl bug)
        elsif ($attr ne 'shared') {
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


### Array-based Object Support ###

# Object ID counters - one for each class tree possibly per thread
my %ID_COUNTERS;
# Reclaimed object IDs
my %RECLAIMED_IDS;

if ($threads::shared::threads_shared) {
    threads::shared::share(%ID_COUNTERS);
    threads::shared::share(%RECLAIMED_IDS);
}

# Supplies an ID for an object being created in a class tree
# and reclaims IDs from destroyed objects
sub _ID :Sub
{
    return if $TERMINATING;           # Ignore during global cleanup

    my ($class, $id) = @_;            # The object's class and id
    my $tree = $ID_SUBS{$class}[1];   # The object's class tree

    # If class is sharing, then all ID tracking is done as though in thread 0,
    # else tracking is done per thread
    my $thread_id = (is_sharing($class)) ? 0 : $THREAD_ID;

    # Save deleted IDs for later reuse
    if ($id) {
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
sub sub_name :Sub(Private)
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
sub initialize :Sub(Private)
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
                        # Verify that all the ID subs in hierarchy are the same
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

    # Process field attributes
    process_fields();

    # Implement UNIVERSAL::can/isa with :AutoMethods
    if (%AUTOMETHODS) {
        install_UNIVERSAL();
    }

    # Implement overload (-ify) operators
    if (%OVERLOAD) {
        generate_OVERLOAD();
        undef(%OVERLOAD);
    }

    # Add metadata for methods
    foreach my $pkg (keys(%METHODS)) {
        my %meta;
        while (my $info = shift(@{$METHODS{$pkg}})) {
            my ($code, $location) = @{$info};
            my $kind = pop(@{$info});
            my $name = sub_name($code, ':METHOD', $location);
            $info->[2] = $name;
            $meta{$name}{'kind'} = lc($kind);
        }
        add_meta($pkg, \%meta);
    }
    undef(%METHODS);

    # Add metadata for subroutines
    foreach my $pkg (keys(%SUBROUTINES)) {
        my %meta;
        while (my $info = shift(@{$SUBROUTINES{$pkg}})) {
            my ($code, $location, $name) = @{$info};
            if (! $name) {
                $name = sub_name($code, ':SUB', $location);
                $info->[2] = $name;
            }
            $meta{$name}{'hidden'} = 1;
        }
        add_meta($pkg, \%meta);
    }
    undef(%SUBROUTINES);

    # Implement merged argument methods
    foreach my $pkg (keys(%ARG_WRAP)) {
        my %meta;
        while (my $info = shift(@{$ARG_WRAP{$pkg}})) {
            my ($code, $location, $name) = @{$info};
            if (! $name) {
                $name = sub_name($code, ':MergeArgs', $location);
                $info->[2] = $name;
            }
            my $new_code = create_ARG_WRAP($code);
            *{$pkg.'::'.$name} = $new_code;
            $info->[0] = $new_code;
            $meta{$name}{'merge_args'} = 1;
        }
        add_meta($pkg, \%meta);
    }
    undef(%ARG_WRAP);

    # Implement restricted methods - only callable within hierarchy
    foreach my $pkg (keys(%RESTRICTED)) {
        my %meta;
        while (my $info = shift(@{$RESTRICTED{$pkg}})) {
            my ($code, $location, $name) = @{$info};
            if (! $name) {
                $name = sub_name($code, ':RESTRICTED', $location);
                $info->[2] = $name;
            }
            my $new_code = create_RESTRICTED($pkg, $name, $code);
            *{$pkg.'::'.$name} = $new_code;
            $info->[0] = $new_code;
            $meta{$name}{'restricted'} = 1;
        }
        add_meta($pkg, \%meta);
    }
    undef(%RESTRICTED);

    # Implement private methods - only callable from class itself
    foreach my $pkg (keys(%PRIVATE)) {
        my %meta;
        while (my $info = shift(@{$PRIVATE{$pkg}})) {
            my ($code, $location, $name) = @{$info};
            if (! $name) {
                $name = sub_name($code, ':PRIVATE', $location);
                $info->[2] = $name;
            }
            my $new_code = create_PRIVATE($pkg, $name, $code);
            *{$pkg.'::'.$name} = $new_code;
            $info->[0] = $new_code;
            $meta{$name}{'hidden'} = 1;
        }
        add_meta($pkg, \%meta);
    }
    undef(%PRIVATE);

    # Implement hidden methods - no longer callable by name
    foreach my $pkg (keys(%HIDDEN)) {
        my %meta;
        while (my $info = shift(@{$HIDDEN{$pkg}})) {
            my ($code, $location, $name) = @{$info};
            if (! $name) {
                $name = sub_name($code, ':HIDDEN', $location);
                $info->[2] = $name;
            }
            *{$pkg.'::'.$name} = create_HIDDEN($pkg, $name);
            $meta{$name}{'hidden'} = 1;
        }
        add_meta($pkg, \%meta);
    }
    undef(%HIDDEN);

    # Implement cumulative methods
    if (%CUMULATIVE || %ANTICUMULATIVE) {
        generate_CUMULATIVE();
        undef(%CUMULATIVE);
        undef(%ANTICUMULATIVE);
    }

    # Implement chained methods
    if (%CHAINED || %ANTICHAINED) {
        generate_CHAINED();
        undef(%CHAINED);
        undef(%ANTICHAINED);
    }

    # Export methods
    export_methods();
}


# Process attributes for field hashes/arrays including generating accessors
sub process_fields :Sub(Private)
{
    # 'Want' module loaded?
    my $use_want = (defined($Want::VERSION) && ($Want::VERSION >= 0.12));

    # Process field attributes
    foreach my $pkg (keys(%NEW_FIELDS)) {
        foreach my $item (@{$NEW_FIELDS{$pkg}}) {
            my ($fld, $attr) = @{$item};

            # Share the field, if applicable
            if (is_sharing($pkg) && !threads::shared::_id($fld)) {
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
            if ($attr) {
                create_accessors($pkg, $fld, $attr, $use_want);
            }

            # Save field ref
            if (! grep { $_ == $fld } @{$FIELDS{$pkg}}) {
                push(@{$FIELDS{$pkg}}, $fld);
            }
        }
    }
    undef(%NEW_FIELDS);  # No longer needed

    # Verify any 'hash field only' classes
    foreach my $ho (keys(%HASH_ONLY)) {
        CHECK:
        foreach my $class (keys(%TREE_TOP_DOWN)) {
            foreach my $pkg (@{$TREE_TOP_DOWN{$class}}) {
                if ($pkg eq $ho) {
                    if (grep { ref ne 'HASH' } @{$FIELDS{$class}}) {
                        my $loc = ((caller())[1] =~ /Dynamic/)
                                    ? [ (caller(2))[0..2] ] : $HASH_ONLY{$ho};
                        OIO::Code->die(
                            'location' => $loc,
                            'message'  => "Can't combine 'hash only' classes ($ho) with array-based classes ($class) in the same class tree",
                            'Info'     => "Class '$ho' was declared as ':hash_only', but class '$class' has array-based fields");
                    }
                    next CHECK;
                }
            }
        }
    }
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

sub set_sharing :Sub(Private)
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
sub is_sharing :Sub(Private)
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
    # Don't execute when called for sub-classes
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

    # Fix field references
    %WEAK       = map { $_ => 1 } @WEAKEN;
    %DEEP_CLONE = map { $_ => 1 } @DEEP_CLONERS;
    %FIELD_TYPE = map { $_->[0] => $_->[1] } @FIELD_TYPE_INFO;

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
                local $SIG{'__DIE__'} = 'OIO::trap';
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
                        local $SIG{'__DIE__'} = 'OIO::trap';
                        $replicate->($pseudo_object, $obj, 'CLONE');
                    }
                }
            }
        }
    }
}


### Object Methods ###

my @EXPORT = qw(new clone meta set DESTROY);

# Helper subroutine to export methods to classes
sub export_methods :Sub(Private)
{
    my @EXPORT_STORABLE = qw(STORABLE_freeze STORABLE_thaw);

    no strict 'refs';

    foreach my $pkg (keys(%TREE_TOP_DOWN)) {
        my %meta;
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

                # Add metadata
                if ($sym eq 'new') {
                    $meta{'new'} = { 'kind' => 'constructor',
                                     'merge_args' => 1 };

                } elsif ($sym eq 'clone' || $sym eq 'dump') {
                    $meta{$sym}{'kind'} = 'object';

                } elsif ($sym eq 'create_field') {
                    $meta{$sym}{'kind'} = 'class';

                } elsif ($sym =~ /^STORABLE_/ ||
                         $sym eq 'AUTOLOAD')
                {
                    $meta{$sym}{'hidden'} = 1;

                } elsif ($sym =~ /herit/ || $sym eq 'set') {
                    $meta{$sym} = { 'kind' => 'object',
                                    'restricted' => 1 };
                }
            }
        }
        add_meta($pkg, \%meta);
    }
}


# Helper subroutine to create a new 'bare' object
sub _obj :Sub(Private)
{
    my $class = shift;

    # Create a new 'bare' object
    my $self = create_object($class, $ID_SUBS{$class}[0]);

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


# Extracts specified args from those given
sub _args :Sub(Private)
{
    my $class = shift;
    my $self  = shift;   # Object being initialized with args
    my $spec  = shift;   # Hash ref of arg specifiers
    my $args  = shift;   # Hash ref of args

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
                    'message' => "Bad class initializer for '$class'",
                    'Usage'   => q/Class initializers must be a hash ref/,
                    'ignore_package' => __PACKAGE__);
            }
            # Loop back to process class-specific arguments
            redo EXTRACT;
        }
    }

    # Check on what we've found
    CHECK:
    foreach my $key (keys(%{$spec})) {
        my $spec_item = $spec->{$key};
        # No specs to check
        if (ref($spec_item) ne 'HASH') {
            # The specifier entry was just 'key => regex'.  If 'key' is not in
            # the args, the we need to remove the 'undef' entry in the found
            # args hash.
            if (! defined($found{$key})) {
                delete($found{$key});
            }
            next CHECK;
        }

        # Preprocess the argument
        if (my $pre = hash_re($spec_item, qr/^PRE/i)) {
            if (ref($pre) ne 'CODE') {
                OIO::Code->die(
                    'message' => q/Can't handle argument/,
                    'Info'    => "'Preprocess' is not a code ref for initializer '$key' for class '$class'",
                    'ignore_package' => __PACKAGE__);
            }

            my (@errs);
            local $SIG{'__WARN__'} = sub { push(@errs, @_); };
            eval {
                local $SIG{'__DIE__'};
                $found{$key} = $pre->($class, $key, $spec_item, $self, $found{$key})
            };
            if ($@ || @errs) {
                my ($err) = split(/ at /, $@ || join(" | ", @errs));
                OIO::Code->die(
                    'message' => "Problem with preprocess routine for initializer '$key' for class '$class",
                    'Error'   => $err,
                    'ignore_package' => __PACKAGE__);
            }
        }

        # Handle args not found
        if (! defined($found{$key})) {
            # Complain if mandatory
            if (hash_re($spec_item, qr/^(?:MAND|REQ)/i)) {
                OIO::Args->die(
                    'message' => "Missing mandatory initializer '$key' for class '$class'",
                    'ignore_package' => __PACKAGE__);
            }

            # Assign default value
            $found{$key} = Object::InsideOut::Util::clone(
                                hash_re($spec_item, qr/^DEF(?:AULTs?)?$/i)
                           );

            # If no default, then remove it from the found args hash
            if (! defined($found{$key})) {
                delete($found{$key});
                next CHECK;
            }
        }

        # Check for correct type
        if (my $type = hash_re($spec_item, qr/^TYPE$/i)) {
            # Custom type checking
            if (ref($type)) {
                if (ref($type) ne 'CODE') {
                    OIO::Code->die(
                        'message' => q/Can't validate argument/,
                        'Info'    => "'Type' is not a code ref or string for initializer '$key' for class '$class'",
                        'ignore_package' => __PACKAGE__);
                }

                my ($ok, @errs);
                local $SIG{'__WARN__'} = sub { push(@errs, @_); };
                eval {
                    local $SIG{'__DIE__'};
                    $ok = $type->($found{$key})
                };
                if ($@ || @errs) {
                    my ($err) = split(/ at /, $@ || join(" | ", @errs));
                    OIO::Code->die(
                        'message' => "Problem with type check routine for initializer '$key' for class '$class",
                        'Error'   => $err,
                        'ignore_package' => __PACKAGE__);
                }
                if (! $ok) {
                    OIO::Args->die(
                        'message' => "Initializer '$key' for class '$class' failed type check: $found{$key}",
                        'ignore_package' => __PACKAGE__);
                }
            }

            # Is it supposed to be a number
            elsif ($type =~ /^num/i) {
                if (! Scalar::Util::looks_like_number($found{$key})) {
                OIO::Args->die(
                    'message' => "Bad value for initializer '$key': $found{$key}",
                    'Usage'   => "Initializer '$key' for class '$class' must be a number",
                    'ignore_package' => __PACKAGE__);
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
            else {
                if ($type =~ /^(array|hash)(?:_?ref)?$/i) {
                    $type = uc($1);
                }
                if (! is_it($found{$key}, $type)) {
                    OIO::Args->die(
                        'message' => "Bad value for initializer '$key': $found{$key}",
                        'Usage'   => "Initializer '$key' for class '$class' must be an object or ref of type '$type'",
                        'ignore_package' => __PACKAGE__);
                }
            }
        }

        # If the destination field is specified, then put it in, and remove it
        # from the found args hash.  If thread-sharing, then make sure the
        # value is thread-shared.
        if (my $field = hash_re($spec_item, qr/^FIELD$/i)) {
            $self->set($field, delete($found{$key}));
        }
    }

    # Done - return remaining found args
    return (\%found);
}


# Object Constructor
sub new :MergeArgs
{
    my ($thing, $all_args) = @_;
    my $class = ref($thing) || $thing;

    # Can't call ->new() on this package
    if ($class eq __PACKAGE__) {
        OIO::Method->die('message' => q/'new' called on non-class 'Object::InsideOut'/);
    }

    # Perform package initialization, if required
    initialize() if ($DO_INIT);

    # Create a new 'bare' object
    my $self = _obj($class);

    # Execute pre-initialization subroutines
    foreach my $pkg (@{$TREE_BOTTOM_UP{$class}}) {
        if (my $preinit = $PREINITORS{$pkg}) {
            local $SIG{'__DIE__'} = 'OIO::trap';
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
        my $args = ($spec) ? _args($pkg, $self, $spec, $all_args)
                           : $all_args;

        if ($init) {
            # Send remaining args, if any, to Init subroutine
            local $SIG{'__DIE__'} = 'OIO::trap';
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
        OIO::Method->die('message' => q/'clone' called as a class method/);
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
            local $SIG{'__DIE__'} = 'OIO::trap';
            $parent->$replicate($clone, $deep);
        }
    }

    # Done - return clone
    return ($clone);
}


# Get a metadata object
sub meta
{
    my ($thing, $arg) = @_;
    my $class = ref($thing) || $thing;

    # No metadata for OIO
    if ($class eq __PACKAGE__) {
        OIO::Method->die('message' => q/'meta' called on non-class 'Object::InsideOut'/);
    }

    # Perform package initialization, if required
    initialize() if ($DO_INIT);

    # Get all foreign classes
    my %foreign;
    foreach my $pkg (@{$TREE_BOTTOM_UP{$class}}) {
        if (exists($HERITAGE{$pkg})) {
            @foreign{keys(%{$HERITAGE{$pkg}[1]})} = undef;
        }
    }
    my @foreign = (keys(%foreign));

    return (Object::InsideOut::Metadata->new(
                'INIT_ARGS'     => \%INIT_ARGS,
                'AUTOMETHODS'   => \%AUTOMETHODS,
                'CLASSES'       => $TREE_TOP_DOWN{$class},
                'FOREIGN'       => \@foreign));
}


# Put data in a field, making sure that sharing is supported
sub set
{
    my ($self, $field, $data) = @_;

    # Must call ->set() as an object method
    if (! Scalar::Util::blessed($self)) {
        OIO::Method->die('message' => q/'set' called as a class method/);
    }

    # Restrict usage to inside class hierarchy
    if (! $self->$UNIV_ISA('Object::InsideOut')) {
        my $caller = caller();
        OIO::Method->die('message' => "Can't call restricted method 'inherit' from class '$caller'");
    }

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
            $$field[$$self] = make_shared($data);
        } else {
            $$field{$$self} = make_shared($data);
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
        # Grab any error coming into this routine
        my $err = $@;

        # Workaround for Perl's "in cleanup" bug
        if ($threads::shared::threads_shared && ! $TERMINATING) {
            eval {
                my $bug = keys(%ID_COUNTERS) + keys(%RECLAIMED_IDS) + keys(%SHARED);
            };
            if ($@) {
                $TERMINATING = 1;
            }
        }

        eval {
            my $is_sharing = is_sharing($class);
            if ($is_sharing) {
                # Thread-shared object

                if ($TERMINATING) {
                    return if ($THREAD_ID);   # Continue only if main thread

                } else {
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
            my $dest_err;
            foreach my $pkg (@{$TREE_BOTTOM_UP{$class}}) {
                # Dispatch any special destruction handling
                if (my $destroy = $DESTROYERS{$pkg}) {
                    eval {
                        local $SIG{'__DIE__'} = 'OIO::trap';
                        $self->$destroy();
                    };
                    $dest_err = OIO::combine($dest_err, $@);
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

            # Propagate any errors
            if ($dest_err) {
                die($dest_err);
            }
        };

        # Propagate any errors
        if ($err || $@) {
            $@ = OIO::combine($err, $@);
            die("$@") if (! $err);
        }
    }
}


### Serialization support using Storable ###

sub STORABLE_freeze :Sub
{
    my ($self, $cloning) = @_;
    return ('', $self->dump());
}

sub STORABLE_thaw :Sub
{
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
sub create_accessors :Sub(Private)
{
    my ($pkg, $field_ref, $attr, $use_want) = @_;

    # Extract info from attribute
    my ($kind) = $attr =~ /^(\w+)/;
    my ($name) = $attr =~ /^\w+\s*(?:[(]\s*'?(\w*)'?\s*[)])/;
    my ($decl) = $attr =~ /^\w+\s*(?:[(]\s*(.*)\s*[)])/;

    if ($name) {
        $decl = "{'$kind'=>'$name'}";
        undef($name);
    } elsif (! $decl) {
        return if ($kind =~ /^Field/i);
        OIO::Attribute->die(
            'message'   => "Missing declarations for attribute in package '$pkg'",
            'Attribute' => $attr);
    } elsif ($kind !~ /^Field/i) {
        $decl =~ s/'?name'?\s*=>/'$kind'=>/i;
    }

    # Parse the accessor declaration
    my $acc_spec;
    {
        my @errs;
        local $SIG{'__WARN__'} = sub { push(@errs, @_); };

        if ($decl =~ /^{/) {
            eval "\$acc_spec = $decl";
        } else {
            eval "\$acc_spec = { $decl }";
        }

        if ($@ || @errs) {
            my ($err) = split(/ at /, $@ || join(" | ", @errs));
            OIO::Attribute->die(
                'message'   => "Malformed attribute in package '$pkg'",
                'Error'     => $err,
                'Attribute' => $attr);
        }
    }

    # Get info for accessors
    my ($get, $set, $return, $private, $restricted, $lvalue, $arg, $pre);
    if ($kind !~ /^arg$/i) {
        foreach my $key (keys(%{$acc_spec})) {
            my $key_uc = uc($key);
            my $val = $$acc_spec{$key};

            # :InitArgs
            if ($key_uc =~ /ALL/) {
                $arg = $val;
                if ($key_uc eq 'ALL') {
                    $key_uc = 'ACC';
                }
            } elsif ($key_uc =~ /ARG/) {
                $arg = $val;
                $key_uc = 'IGNORE';
            }

            # Standard accessors
            if ($key_uc =~ /^ST.*D/) {
                $get = 'get_' . $val;
                $set = 'set_' . $val;
            }
            # Get and/or set accessors
            elsif ($key_uc =~ /^ACC|^COM|^MUT|[GS]ET/) {
                # Get accessor
                if ($key_uc =~ /ACC|COM|MUT|GET/) {
                    $get = $val;
                }
                # Set accessor
                if ($key_uc =~ /ACC|COM|MUT|SET/) {
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
                # Check type-checking setting and set default
                if (!$val || (ref($val) && (ref($val) ne 'CODE'))) {
                    OIO::Attribute->die(
                        'message'   => "Can't create accessor method for package '$pkg'",
                        'Info'      => q/Bad 'Type' specifier: Must be a 'string' or code ref/,
                        'Attribute' => $attr);
                }
                if (!ref($val)) {
                    if ($val =~ /^num(?:ber|eric)?/i) {
                        $val = 'NUMERIC';
                    } elsif (uc($val) eq 'LIST' || uc($val) eq 'ARRAY') {
                        $val = 'LIST';
                    } elsif (uc($val) eq 'HASH') {
                        $val = 'HASH';
                    }
                }
                $FIELD_TYPE{$field_ref} = $val;
                push(@FIELD_TYPE_INFO, [ $field_ref, $val ]);
                next;
            }
            # Field name for ->dump()
            elsif ($key_uc eq 'NAME') {
                $name = $val;
            }
            # Set accessor return type
            elsif ($key_uc =~ /^RET(?:URN)?$/) {
                $return = uc($val);
            }
            # Set accessor permission
            elsif ($key_uc =~ /^PERM|^PRIV|^RESTRICT/) {
                if ($key_uc =~ /^PERM/) {
                    $key_uc = uc($val);
                    $val = 1;
                }
                if ($key_uc =~ /^PRIV/) {
                    $private = $val;
                }
                if ($key_uc =~ /^RESTRICT/) {
                    $restricted = $val;
                }
            }
            # :lvalue accessor
            elsif ($key_uc =~ /^LV/) {
                if ($val && !Scalar::Util::looks_like_number($val)) {
                    $get = $val;
                    $set = $val;
                    $lvalue = 1;
                } else {
                    $lvalue = $val;
                }
            }
            # Preprocessor
            elsif ($key_uc =~ /^PRE/) {
                $pre = $val;
                if (ref($pre) ne 'CODE') {
                    OIO::Attribute->die(
                        'message'   => "Can't create accessor method for package '$pkg'",
                        'Info'      => q/Bad 'Preprocessor' specifier: Must be a code ref/,
                        'Attribute' => $attr);
                }
            }
            # Unknown parameter
            elsif ($key_uc ne 'IGNORE') {
                OIO::Attribute->die(
                    'message' => "Can't create accessor method for package '$pkg'",
                    'Info'    => "Unknown accessor specifier: $key");
            }

            # $val must have a usable value
            if (! defined($val) || $val eq '') {
                OIO::Attribute->die(
                    'message'   => "Invalid '$key' entry in attribute",
                    'Attribute' => $attr);
            }
        }
    }

    # :InitArgs
    if ($arg || ($kind =~ /^ARG$/i)) {
        if (!$arg) {
            $arg = hash_re($acc_spec, qr/^ARG$/i);
            $INIT_ARGS{$pkg}{$arg} = $acc_spec;
        }
        if (!defined($name)) {
            $name = $arg;
        }
        $INIT_ARGS{$pkg}{$arg}{'FIELD'} = $field_ref;
        # Add type to :InitArgs
        if (my $type = $FIELD_TYPE{$field_ref}) {
            if (! hash_re($INIT_ARGS{$pkg}{$arg}, qr/^TYPE$/i)) {
                $INIT_ARGS{$pkg}{$arg}{'TYPE'} = $type;
            }
        }
    }

    # Add field info for dump()
    if ($name) {
        if (exists($DUMP_FIELDS{$pkg}{$name}) &&
            $field_ref != $DUMP_FIELDS{$pkg}{$name}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$pkg'",
                'Info'      => "'$name' already specified for another field using '$DUMP_FIELDS{$pkg}{$name}[1]'",
                'Attribute' => $attr);
        }
        $DUMP_FIELDS{$pkg}{$name} = [ $field_ref, 'Name' ];
        # Done if only 'Name' present
        if (! $get && ! $set && ! $return && ! $lvalue) {
            return;
        }

    } elsif ($get) {
        if (exists($DUMP_FIELDS{$pkg}{$get}) &&
            $field_ref != $DUMP_FIELDS{$pkg}{$get}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$pkg'",
                'Info'      => "'$get' already specified for another field using '$DUMP_FIELDS{$pkg}{$get}[1]'",
                'Attribute' => $attr);
        }
        if (! exists($DUMP_FIELDS{$pkg}{$get}) ||
            ($DUMP_FIELDS{$pkg}{$get}[1] ne 'Name'))
        {
            $DUMP_FIELDS{$pkg}{$get} = [ $field_ref, 'Get' ];
        }

    } elsif ($set) {
        if (exists($DUMP_FIELDS{$pkg}{$set}) &&
            $field_ref != $DUMP_FIELDS{$pkg}{$set}[0])
        {
            OIO::Attribute->die(
                'message'   => "Can't create accessor method for package '$pkg'",
                'Info'      => "'$set' already specified for another field using '$DUMP_FIELDS{$pkg}{$set}[1]'",
                'Attribute' => $attr);
        }
        if (! exists($DUMP_FIELDS{$pkg}{$set}) ||
            ($DUMP_FIELDS{$pkg}{$set}[1] ne 'Name'))
        {
            $DUMP_FIELDS{$pkg}{$set} = [ $field_ref, 'Set' ];
        }
    } elsif (! $return && ! $lvalue) {
        return;
    }

    # If 'RETURN' or 'LVALUE', need 'SET', too
    if (($return || $lvalue) && ! $set) {
        OIO::Attribute->die(
            'message'   => "Can't create accessor method for package '$pkg'",
            'Info'      => "No set accessor specified to go with 'RETURN'/'LVALUE'",
            'Attribute' => $attr);
    }

    # Check for name conflict
    foreach my $method ($get, $set) {
        if ($method) {
            no strict 'refs';
            # Do not overwrite existing methods
            if (*{$pkg.'::'.$method}{CODE}) {
                OIO::Attribute->die(
                    'message'   => q/Can't create accessor method/,
                    'Info'      => "Method '$method' already exists in class '$pkg'",
                    'Attribute' => $attr);
            }
        }
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
            'Attribute' => $attr);
    }

    # Get type checking (if any)
    my $type = $FIELD_TYPE{$field_ref} || 'NONE';

    # Metadata
    my %meta;
    if ($set) {
        $meta{$set}{'kind'} = ($get && ($get eq $set)) ? 'accessor' : 'set';
        if ($lvalue) {
            $meta{$set}{'lvalue'} = 1;
        }
        $meta{$set}{'return'} = lc($return);
    }
    if ($get && (!$set || ($get ne $set))) {
        $meta{$get}{'kind'} = 'get';
    }
    foreach my $meth ($get, $set) {
        next if (! $meth);
        # Type
        if (ref($type)) {
            $meta{$meth}{'type'} = $type;
        } elsif ($type eq 'NUMERIC') {
            $meta{$meth}{'type'} = 'numeric';
        } elsif ($type eq 'LIST' || $type =~ /^array(?:_?ref)?$/i) {
            $meta{$meth}{'type'} = 'ARRAY';
        } elsif ($type =~ /^hash(?:_?ref)?$/i) {
            $meta{$meth}{'type'} = 'HASH';
        } elsif ($type ne 'NONE') {
            $meta{$meth}{'type'} = $type;
        }
        # Permissions
        if ($private) {
            $meta{$meth}{'hidden'} = 1;
        } elsif ($restricted) {
            $meta{$meth}{'restricted'} = 1;
        }
    }
    add_meta($pkg, \%meta);

    # Code to be eval'ed into subroutines
    my $code = "package $pkg;\n";

    # Create an :lvalue accessor
    if ($lvalue) {
        $code .= create_lvalue_accessor($pkg, $set, $field_ref, $get,
                                        $type, $name, $return, $private,
                                        $restricted, $WEAK{$field_ref}, $pre);
    }

    # Create 'set' or combination accessor
    elsif ($set) {
        # Begin with subroutine declaration in the appropriate package
        $code .= "*${pkg}::$set = sub {\n";

        $code .= preamble_code($pkg, $set, $private, $restricted);

        my $fld_str = (ref($field_ref) eq 'HASH') ? "\$field->\{\${\$_[0]}}" : "\$field->\[\${\$_[0]}]";

        # Add GET portion for combination accessor
        if ($get && ($get eq $set)) {
            $code .= "    return ($fld_str) if (\@_ == 1);\n";
        }

        # If set only, then must have at least one arg
        else {
            $code .= <<"_CHECK_ARGS_";
    if (\@_ < 2) {
        OIO::Args->die(
            'message'  => q/Missing arg(s) to '$pkg->$set'/,
            'location' => [ caller() ]);
    }
_CHECK_ARGS_
        }

        # Add preprocessing code block
        if ($pre) {
            $code .= <<"_PRE_";
    {
        my \@errs;
        local \$SIG{'__WARN__'} = sub { push(\@errs, \@_); };
        eval {
            my \$self = shift;
            \@_ = (\$self, \$preproc->(\$self, \$field, \@_));
        };
        if (\$@ || \@errs) {
            my (\$err) = split(/ at /, \$@ || join(" | ", \@errs));
            OIO::Code->die(
                'message' => q/Problem with preprocessing routine for '$pkg->$set'/,
                'Error'   => \$err);
        }
    }
_PRE_
        }

        # Add data type checking
        my $arg_str = '$_[1]';
        if (ref($type)) {
            $code .= <<"_CODE_";
    {
        my (\$ok, \@errs);
        local \$SIG{'__WARN__'} = sub { push(\@errs, \@_); };
        eval { \$ok = \$type_check->($arg_str) };
        if (\$@ || \@errs) {
            my (\$err) = split(/ at /, \$@ || join(" | ", \@errs));
            OIO::Code->die(
                'message' => q/Problem with type check routine for '$pkg->$set'/,
                'Error'   => \$err);
        }
        if (! \$ok) {
            OIO::Args->die(
                'message'  => "Argument to '$pkg->$set' failed type check: $arg_str",
                'location' => [ caller() ]);
        }
    }
_CODE_

        } elsif ($type eq 'NONE') {
            # For 'weak' fields, the data must be a ref
            if ($WEAK{$field_ref}) {
                $code .= <<"_WEAK_";
    if (! ref($arg_str)) {
        OIO::Args->die(
            'message'  => "Bad argument: $arg_str",
            'Usage'    => q/Argument to '$pkg->$set' must be a reference/,
            'location' => [ caller() ]);
    }
_WEAK_
            }

        } elsif ($type eq 'NUMERIC') {
            # One numeric argument
            $code .= <<"_NUMERIC_";
    if (! Scalar::Util::looks_like_number($arg_str)) {
        OIO::Args->die(
            'message'  => "Bad argument: $arg_str",
            'Usage'    => q/Argument to '$pkg->$set' must be numeric/,
            'location' => [ caller() ]);
    }
_NUMERIC_

        } elsif ($type eq 'LIST') {
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
            $arg_str = '$arg';

        } elsif ($type eq 'HASH') {
            # Hash - pairs of args or hash ref
            $code .= <<"_HASH_";
    my \$arg;
    if (\@_ == 2 && ref(\$_[1]) eq 'HASH') {
        \$arg = \$_[1];
    } elsif (\@_ % 2 == 0) {
        OIO::Args->die(
            'message'  => q/Odd number of arguments: Can't create hash ref/,
            'Usage'    => q/'$pkg->$set' requires a hash ref or an even number of args (to make a hash ref)/,
            'location' => [ caller() ]);
    } else {
        my \@args = \@_;
        shift(\@args);
        my \%args = \@args;
        \$arg = \\\%args;
    }
_HASH_
            $arg_str = '$arg';

        } else {
            # Support explicit specification of array refs and hash refs
            if (uc($type) =~ /^ARRAY_?REF$/) {
                $type = 'ARRAY';
            } elsif (uc($type) =~ /^HASH_?REF$/) {
                $type = 'HASH';
            }

            # One object or ref arg - exact spelling and case required
            $code .= <<"_REF_";
    if (! Object::InsideOut::Util::is_it($arg_str, '$type')) {
        OIO::Args->die(
            'message'  => q/Bad argument: Wrong type/,
            'Usage'    => q/Argument to '$pkg->$set' must be of type '$type'/,
            'location' => [ caller() ]);
    }
_REF_
        }

        # Add field locking code if sharing
        if (is_sharing($pkg)) {
            $code .= "    lock(\$field);\n"
        }

        # Grab 'OLD' value
        if ($return eq 'OLD') {
            $code .= "    my \$ret = $fld_str;\n";
        }

        # Add actual 'set' code
        $code .= (is_sharing($pkg))
              ? "    $fld_str = Object::InsideOut::Util::make_shared($arg_str);\n"
              : "    $fld_str = $arg_str;\n";
        if ($WEAK{$field_ref}) {
            $code .= "    Scalar::Util::weaken($fld_str);\n";
        }

        # Add code for return value
        if ($return eq 'SELF') {
            $code .= "    \$_[0];\n";
        } elsif ($return eq 'OLD') {
            if ($use_want) {
                $code .= "    ((Want::wantref() eq 'OBJECT') && !Scalar::Util::blessed(\$ret)) ? \$_[0] : ";
            }
            $code .= "\$ret;\n";
        } elsif ($use_want) {
            $code .= "    ((Want::wantref() eq 'OBJECT') && !Scalar::Util::blessed($fld_str)) ? \$_[0] : $fld_str;\n";
        } elsif ($WEAK{$field_ref}) {
            $code .= "    $fld_str;\n";
        }

        # Done
        $code .= "};\n";
    }
    undef($type) if (! ref($type));

    # Create 'get' accessor
    if ($get && (!$set || ($get ne $set))) {
        $code .= "*${pkg}::$get = sub {\n"

               . preamble_code($pkg, $get, $private, $restricted)

               . ((ref($field_ref) eq 'HASH')
                    ? "    \$field->{\${\$_[0]}};\n};\n"
                    : "    \$field->[\${\$_[0]}];\n};\n");
    }

    # Inspect generated code
    print("\n", $code, "\n") if $Object::InsideOut::DEBUG;

    # Compile the subroutine(s) in the smallest possible lexical scope
    my @errs;
    local $SIG{'__WARN__'} = sub { push(@errs, @_); };
    {
        my $field      = $field_ref;
        my $type_check = $type;
        my $preproc    = $pre;
        eval $code;
    }
    if ($@ || @errs) {
        my ($err) = split(/ at /, $@ || join(" | ", @errs));
        OIO::Internal->die(
            'message'     => "Failure creating accessor for class '$pkg'",
            'Error'       => $err,
            'Declaration' => $attr,
            'Code'        => $code,
            'self'        => 1);
    }
}

# Generate code for start of accessor
sub preamble_code :Sub(Private)
{
    my ($pkg, $name, $private, $restricted) = @_;
    my $code = '';

    # Permission checking code
    if ($private) {
        $code .= <<"_PRIVATE_";
    my \$caller = caller();
    if (\$caller ne '$pkg') {
        OIO::Method->die('message' => "Can't call private method '$pkg->$name' from class '\$caller'");
    }
_PRIVATE_
    } elsif ($restricted) {
        $code .= <<"_RESTRICTED_";
    my \$caller = caller();
    if (! \$caller->isa('$pkg') && ! $pkg->isa(\$caller)) {
        OIO::Method->die('message'  => "Can't call restricted method '$pkg->$name' from class '\$caller'");
    }
_RESTRICTED_
    }

    return ($code);
}


### Method/subroutine Wrappers ###

# Returns a 'wrapper' closure back to initialize() that adds merged argument
# support for a method.
sub create_ARG_WRAP :Sub(Private)
{
    my $code = shift;
    return sub {
        my $self = shift;

        # Gather arguments into a single hash ref
        my $args = {};
        while (my $arg = shift) {
            if (ref($arg) eq 'HASH') {
                # Add args from a hash ref
                @{$args}{keys(%{$arg})} = values(%{$arg});
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
                $$args{$arg} = shift;
            }
        }

        @_ = ($self, $args);
        goto $code;
    };
}

# Returns a 'wrapper' closure back to initialize() that restricts a method
# to being only callable from within its class hierarchy
sub create_RESTRICTED :Sub(Private)
{
    my ($pkg, $method, $code) = @_;
    return sub {
        # Caller must be in class hierarchy
        my $caller = caller();
        if (! ($caller->$UNIV_ISA($pkg) || $pkg->$UNIV_ISA($caller))) {
            OIO::Method->die('message' => "Can't call restricted method '$pkg->$method' from class '$caller'");
        }
        goto $code;
    };
}


# Returns a 'wrapper' closure back to initialize() that makes a method
# private (i.e., only callable from within its own class).
sub create_PRIVATE :Sub(Private)
{
    my ($pkg, $method, $code) = @_;
    return sub {
        # Caller must be in the package
        my $caller = caller();
        if ($caller ne $pkg) {
            OIO::Method->die('message' => "Can't call private method '$pkg->$method' from class '$caller'");
        }
        goto $code;
    };
}


# Returns a 'wrapper' closure back to initialize() that makes a subroutine
# uncallable - with the original code ref stored elsewhere, of course.
sub create_HIDDEN :Sub(Private)
{
    my ($pkg, $method) = @_;
    return sub {
        OIO::Method->die('message' => "Can't call hidden method '$pkg->$method'");
    }
}


### Delayed Loading ###

# Loads sub-modules
sub load :Sub(Private)
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

sub generate_CUMULATIVE :Sub(Private)
{
    load('Cumulative');

    @_ = (\%CUMULATIVE, \%ANTICUMULATIVE, \%TREE_TOP_DOWN, \%TREE_BOTTOM_UP,
          $UNIV_ISA);

    goto &generate_CUMULATIVE;
}

sub create_CUMULATIVE :Sub(Private)
{
    load('Cumulative');
    goto &create_CUMULATIVE;
}

sub generate_CHAINED :Sub(Private)
{
    load('Chained');

    @_ = (\%CHAINED, \%ANTICHAINED, \%TREE_TOP_DOWN, \%TREE_BOTTOM_UP,
          $UNIV_ISA);

    goto &generate_CHAINED;
}

sub create_CHAINED :Sub(Private)
{
    load('Chained');
    goto &create_CHAINED;
}

sub generate_OVERLOAD :Sub(Private)
{
    load('Overload');

    @_ = (\%OVERLOAD, \%TREE_TOP_DOWN);

    goto &generate_OVERLOAD;
}

sub install_UNIVERSAL :Sub
{
    load('Universal');

    @_ = ($UNIV_ISA, $UNIV_CAN, \%AUTOMETHODS, \%HERITAGE, \%TREE_BOTTOM_UP);

    goto &install_UNIVERSAL;
}

sub install_ATTRIBUTES :Sub
{
    load('attributes');

    @_ = (\%ATTR_HANDLERS, \%TREE_BOTTOM_UP);

    goto &install_ATTRIBUTES;
}

sub dump :Method(Object)
{
    load('Dump');

    push(@EXPORT, 'dump');
    $DO_INIT = 1;

    @_ = (\@DUMP_INITARGS, \%DUMP_FIELDS, \%DUMPERS, \%PUMPERS,
          \%INIT_ARGS, \%TREE_TOP_DOWN, \%FIELDS, \%WEAK, 'dump', @_);

    goto &dump;
}

sub pump :Method(Class)
{
    load('Dump');

    push(@EXPORT, 'dump');
    $DO_INIT = 1;

    @_ = (\@DUMP_INITARGS, \%DUMP_FIELDS, \%DUMPERS, \%PUMPERS,
          \%INIT_ARGS, \%TREE_TOP_DOWN, \%FIELDS, \%WEAK, 'pump', @_);

    goto &dump;
}

sub inherit :Method(Object)
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'inherit', @_);

    goto &inherit;
}

sub heritage :Method(Object)
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'heritage', @_);

    goto &inherit;
}

sub disinherit :Method(Object)
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'disinherit', @_);

    goto &inherit;
}

sub create_heritage :Sub(Private)
{
    load('Foreign');

    push(@EXPORT, qw(inherit heritage disinherit));
    $DO_INIT = 1;

    @_ = ($UNIV_ISA, \%HERITAGE, \%DUMP_FIELDS, \%FIELDS, 'create_heritage', @_);

    goto &inherit;
}

sub create_field :Method(Class)
{
    load('Dynamic');

    push(@EXPORT, 'create_field');
    $DO_INIT = 1;

    unshift(@_, $UNIV_ISA);

    goto &create_field;
}

sub AUTOLOAD :Sub
{
    load('Autoload');

    push(@EXPORT, 'AUTOLOAD');
    $DO_INIT = 1;

    @_ = (\%TREE_TOP_DOWN, \%TREE_BOTTOM_UP, \%HERITAGE, \%AUTOMETHODS, @_);

    goto &Object::InsideOut::AUTOLOAD;
}

sub create_lvalue_accessor :Sub(Private)
{
    load('lvalue');
    goto &create_lvalue_accessor;
}

}  # End of package's lexical scope

1;

__END__

=head1 NAME

Object::InsideOut - Comprehensive inside-out object support module

=head1 VERSION

This document describes Object::InsideOut version 2.06

=head1 SYNOPSIS

 package My::Class; {
     use Object::InsideOut;

     # Numeric field
     #   With combined get+set accessor
     my @data
            :Field
            :Type(Numeric)
            :Accessor(data);

     # Takes 'INPUT' (or 'input', etc.) as a mandatory parameter to ->new()
     my %init_args :InitArgs = (
         'INPUT' => {
             'Regex'     => qr/^input$/i,
             'Mandatory' => 1,
             'Type'      => 'NUMERIC',
         },
     );

     # Handle class-specific args as part of ->new()
     sub init :Init
     {
         my ($self, $args) = @_;

         # Put 'input' parameter into 'data' field
         $self->set(\@data, $args->{'INPUT'});
     }
 }

 package My::Class::Sub; {
     use Object::InsideOut qw(My::Class);

     # List field
     #   With standard 'get_X' and 'set_X' accessors
     #   Takes 'INFO' as an optional list parameter to ->new()
     #     Value automatically added to @info array
     #     Defaults to [ 'empty' ]
     my @info
            :Field
            :Type(List)
            :Standard(info)
            :Arg('Name' => 'INFO', 'Default' => 'empty');
 }

 package Foo; {
     use Object::InsideOut;

     # Field containing My::Class objects
     #   With combined accessor
     #   Plus automatic parameter processing on object creation
     my @foo
            :Field
            :Type(My::Class)
            :All(foo);
 }

 package main;

 my $obj = My::Class::Sub->new('Input' => 69);
 my $info = $obj->get_info();               # [ 'empty' ]
 my $data = $obj->data();                   # 69
 $obj->data(42);
 $data = $obj->data();                      # 42

 $obj = My::Class::Sub->new('INFO' => 'help', 'INPUT' => 86);
 $data = $obj->data();                      # 86
 $info = $obj->get_info();                  # [ 'help' ]
 $obj->set_info(qw(foo bar baz));
 $info = $obj->get_info();                  # [ 'foo', 'bar', 'baz' ]

 my $foo_obj = Foo->new('foo' => $obj);
 $foo_obj->foo()->data();                   # 86

=head1 DESCRIPTION

This module provides comprehensive support for implementing classes using the
inside-out object model.

Object::InsideOut implements inside-out objects as anonymous scalar references
that are blessed into a class with the scalar containing the ID for the object
(usually a sequence number).  For Perl 5.8.3 and later, the scalar reference
is set as B<read-only> to prevent I<accidental> modifications to the ID.
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

Object::InsideOut offers all the capabilities of other inside-out object
modules with the following additional key advantages:

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
matching, and much more.

=item * Runtime Support

Supports classes that may be loaded at runtime (i.e., using
S<C<eval { require ...; };>>).  This makes it usable from within L<mod_perl>,
as well.  Also supports dynamic creation of object fields during runtime.

=item * Perl 5.6 and 5.8

Tested on Perl v5.6.0 through v5.6.2, v5.8.0 through v5.8.8, and v5.9.4.

=item * Exception Objects

Object::InsideOut uses L<Exception::Class> for handling errors in an
OO-compatible manner.

=item * Object Serialization

Object::InsideOut has built-in support for object dumping and reloading that
can be accomplished in either an automated fashion or through the use of
class-supplied subroutines.  Serialization using L<Storable> is also
supported.

=item * Foreign Class Inheritance

Object::InsideOut allows classes to inherit from foreign (i.e.,
non-Object::InsideOut) classes, thus allowing you to sub-class other Perl
class, and access their methods from your own objects.

=item * Introspection

Obtain constructor parameters and method metadata for Object::InsideOut
classes.

=back

=head1 CLASSES

To use this module, each of your classes will start with
S<C<use Object::InsideOut;>>:

 package My::Class; {
     use Object::InsideOut;
     ...
 }

Sub-classes (child classes) inherit from base classes (parent classes) by
telling Object::InsideOut what the parent class is:

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
@ISA array.  Therefore, you should not S<C<use base ...>> yourself, nor try to
set up C<@ISA> arrays.  Further, you should not use a class's C<@ISA> array to
determine a class's hierarchy:  See L</"INTROSPECTION"> for details on how to
do this.

If a parent class takes parameters (e.g., symbols to be exported via
L<Exporter|/"Usage With C<Exporter>">), enclose them in an array ref
(mandatory) following the name of the parent class:

 package My::Project; {
     use Object::InsideOut 'My::Class'      => [ 'param1', 'param2' ],
                           'Another::Class' => [ 'param' ];
     ...
 }

=head1 OBJECTS

=head2 Object Creation

Objects are created using the C<-E<gt>new()> method which is exported by
Object::InsideOut to each class, and is invoked in the following manner:

 my $obj = My::Class->new();

Object::InsideOut then handles all the messy details of initializing the
object in each of the classes in the invoking class's hierarchy.  As such,
classes do not (normally) implement their own C<-E<gt>new()> method.

Usually, object fields are initially populated with data as part of the
object creation process by passing parameters to the C<-E<gt>new()> method.
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

The initialization methods for both classes in the above will get
S<C<'foo' =E<gt> 'bar'>>, C<My::Class> will also get
S<C<'param' =E<gt> 'value'>>, and C<Parent::Class> will also get
S<C<'data' =E<gt> 'info'>>.  In this scheme, class-specific parameters will
override general parameters specified at a higher level:

 my $obj = My::Class->new(
     'default' => 'bar',
     'Parent::Class'  => { 'default' => 'baz' },
 );

C<My::Class> will get S<C<'default' =E<gt> 'bar'>>, and C<Parent::Class> will
get S<C<'default' =E<gt> 'baz'>>.

Calling C<-E<gt>new()> on an object works, too, and operates the same as
calling C<-E<gt>new()> for the class of the object (i.e., C<$obj-E<gt>new()>
is the same as C<ref($obj)-E<gt>new()>).

How the parameters passed to the C<-E<gt>new()> method are used to
initialize the object is discussed later under L</"OBJECT INITIALIZATION">.

NOTE: You cannot create objects from Object::InsideOut itself:

 # This is an error
 # my $obj = Object::InsideOut->new();

In this way, Object::InsideOut is not an object class, but functions more like
a pragma.

=head2 Object IDs

As stated earlier, this module implements inside-out objects as anonymous,
read-only scalar references that are blessed into a class with the scalar
containing the ID for the object.

Within methods, the object is passed in as the first argument:

 sub my_method
 {
     my $self = shift;
     ...
 }

The object's ID is then obtained by dereferencing the object:  C<$$self>.
Normally, this is only needed when accessing the object's field data:

 my @my_field :Field;

 sub my_method
 {
     my $self = shift;
     ...
     my $data = $my_field[$$self];
     ...
 }

At all other times, and especially in application code, the object should be
treated as an I<opaque> entity.

=head1 ATTRIBUTES

Much of the power of Object::InsideOut comes from the use of I<attributes>:
I<Tags> on variables and subroutines that the L<attributes> module sends to
Object::InsideOut at compile time.  Object::InsideOut then makes use of the
information in these tags to handle such operations as object construction,
automatic accessor generation, and so on.

(Note:  The use of attibutes is not the same thing as
L<source filtering|Filter::Simple>.)

An attribute consists of an identifier preceeded by a colon, and optionally
followed by a set of parameters in parentheses.  For example, the attributes
on the following array declare it as an object field, and specify the
generation of an accessor method for that field:

 my @level :Field :Accessor(level);

When multiple attributes are assigned to a single entity, they may all appear
on the same line (as shown above), or on separate lines:

 my @level
     :Field
     :Accessor(level);

However, due to limitations in the Perl parser, the entirety of any one
attribute must be on a single line:

 # This doesn't work
 # my @level
 #     :Field
 #     :Accessor('Name'   => 'level',
 #               'Return' => 'Old');

 # Each attribute must be all on one line
 my @level
     :Field
     :Accessor('Name' => 'level', 'Return' => 'Old');

For Object::InsideOut's purposes, the case of an attribute's name does not
matter:

 my @data :Field;
    # or
 my @data :FIELD;

However, by convention (as denoted in the L<attributes> module), an
attribute's name should not be all lowercase.

=head1 FIELDS

=head2 Field Declarations

Object data fields consist of arrays within a class's package into which data
are stored using the object's ID as the array index.  An array is declared as
being an object field by following its declaration with the C<:Field>
attribute:

 my @info :Field;

Object data fields may also be hashes:

 my %data :Field;

However, as array access is as much as 40% faster than hash access, you should
stick to using arrays.  See L</"HASH ONLY CLASSES"> for more information on
when hashes may be required.

=head2 Getting Data

In class code, data can be fetched directly from an object's field array
(hash) using the object's ID:

 $data = $field[$$self];
     # or
 $data = $field{$$self};

=head2 Setting Data

Analogous to the above, data can be put directly into an object's field array
(hash) using the object's ID:

 $field[$$self] = $data;
     # or
 $field{$$self} = $data;

However, in threaded applications that use data sharing (i.e., use
C<threads::shared>), the above will not work when the object is shared between
threads and the data being stored is either an array, hash or scalar reference
(this includes other objects).  This is because the C<$data> must first be
converted into shared data before it can be put into the field.

Therefore, Object::InsideOut automatically exports a method called
C<-E<gt>set()> to each class.  This method should be used in class code to put
data into object fields whenever there is the possibility that
the class code may be used in an application that uses L<threads::shared>
(i.e., to make your class code B<thread-safe>).  The C<-E<gt>set()> method
handles all details of converting the data to a shared form, and storing it in
the field.

The C<-E<gt>set()> method, requires two arguments:  A reference to the object
field array/hash, and the data (as a scalar) to be put in it:

 my @my_field :Field;

 sub store_data
 {
     my ($self, $data) = @_;
     ...
     $self->set(\@my_field, $data);
 }

To be clear, the C<-E<gt>set()> method is used inside class code; not
application code.  Use it inside any object methods that set data in object
field arrays/hashes.

In the event of a method naming conflict, the C<-E<gt>set()> method can be
called using its fully-qualified name:

 $self->Object::InsideOut::set(\@field, $data);

=head1 OBJECT INITIALIZATION

As stated in L</"Object Creation">, object fields are initially populated with
data as part of the object creation process by passing S<C<key =E<gt> value>>
parameters to the C<-E<gt>new()> method.  These parameters can be processed
automatically into object fields, or can be passed to a class-specific object
initialization subroutine.

=head2 Field-Specific Parameters

When an object creation parameter corresponds directly to an object field, you
can specify for Object::InsideOut to automatically place the parameter into
the field by adding the C<:Arg> attribute to the field declaration:

 my @foo :Field :Arg(foo);

For the above, the following would result in C<$val> being placed in
C<My::Class>'s C<@foo> field during object creation:

 my $obj = My::Class->new('foo' => $val);

=head2 Object Initialization Subroutines

Many times, object initialization parameters do not correspond directly to
object fields, or they may require special handling.  For these, parameter
processing is accomplished through a combination of an C<:InitArgs>
labeled hash, and an C<:Init> labeled subroutine.

The C<:InitArgs> labeled hash specifies the parameters to be extracted from
the argument list supplied to the C<-E<gt>new()> method.  Those parameters
(and only those parameters) which match the keys in the C<:InitArgs> hash are
then packaged together into a single hash ref.  The newly created object and
this parameter hash ref are then sent to the C<:Init> subroutine for
processing.

Here is an example of a class with an I<automatically handled> field and an
I<:Init handled> field:

 package My::Class; {
     use Object::InsideOut;

     # Automatically handled field
     my @my_data  :Field  :Acc(data)  :Arg(MY_DATA);

     # ':Init' handled field
     my @my_field :Field;

     my %init_args :InitArgs = (
         'MY_PARAM' => '',
     );

     sub _init :Init
     {
         my ($self, $args) = @_;

         if (exists($args->{'MY_PARAM'})) {
             $self->set(\@my_field, $args->{'MY_PARAM'});
         }
     }

     ...
 }

An object for this class would be created as follows:

 my $obj = My::Class->new('MY_DATA'  => $dat,
                          'MY_PARAM' => $parm);

This results in, first of all, C<$dat> being placed in the object's
C<@my_data> field because the C<MY_DATA> key is specified in the C<:Arg>
attribute for that field.

Then, C<_init> is invoked with arguments consisting of the object (i.e.,
C<$self>) and a hash ref consisting only of S<C<{ 'MY_PARAM' =E<gt> $param }>>
because the key C<MY_PARAM> is specified in the C<:InitArgs> hash.
C<_init> checks that the parameter C<MY_PARAM> exists in the hash ref, and
then (since it does exist) adds C<$parm> to the object's C<@my_field> field.

Data processed by the C<:Init> subroutine may be placed directly into the
class's field arrays (hashes) using the object's ID (i.e., C<$$self>):

 $my_field[$$self] = $args->{'MY_PARAM'};

However, as shown in the example above, it is strongly recommended that you
use the L<-E<gt>set()|/"Setting Data"> method:

 $self->set(\@my_field, $args->{'MY_PARAM'});

which handles converting the data to a shared format when needed for
applications using L<threads::shared>.

=head2 Mandatory Parameters

Field-specific parameters may be declared mandatory as follows:

 my @data :Field
          :Arg('Name' => 'data', 'Mandatory' => 1);

If a mandatory parameter is missing from the argument list to C<-E<gt>new()>,
an error is generated.

For C<:Init> handled parameters, use:

 my %init_args :InitArgs = (
     'data' => {
         'Mandatory' => 1,
     },
 );

C<Mandatory> may be abbreviated to C<Mand>, and C<Required> or C<Req> are
synonymous.

=head2 Default Values

For optional parameters, defaults can be specified for field-specific
parameters:

 my @data :Field
          :Arg('Name' => 'data', 'Default' => 'foo');

If an optional parameter with a specified default is missing from the argument
list to C<-E<gt>new()>, then the default is assigned to the field when the
object is created.

The format for C<:Init> handled parameters is:

 my %init_args :InitArgs = (
     'data' => {
         'Default' => 'foo',
     },
 );

In this case, if the parameter is missing from the argument list to
C<-E<gt>new()>, then the parameter key is paired with the default value and
added to the C<:Init> argument hash ref (e.g., S<C<{ 'data' =E<gt> 'foo' }>>).

C<Default> may be abbreviated to C<Def>.

=head2 Parameter Name Matching

Rather than having to rely on exact matches to parameter keys in the
C<-E<gt>new()> argument list, you can specify a regular expressions to be used
to match them to field-specific parameters:

 my @param :Field
           :Arg('Name' => 'param', 'Regexp' => qr/^PARA?M$/i);

In this case, the parameter's key could be any of the following: PARAM, PARM,
Param, Parm, param, parm, and so on.  And the following would result in
C<$data> being placed in C<My::Class>'s C<@param> field during object
creation:

 my $obj = My::Class->new('Parm' => $data);

For C<:Init> handled parameters, you would similarly use:

 my %init_args :InitArgs = (
     'Param' => {
         'Regex' => qr/^PARA?M$/i,
     },
 );

In this case, the match results in S<C<{ 'Param' =E<gt> $data }>> being sent
to the C<:Init> subroutine as the argument hash.  Note that the C<:InitArgs>
hash key is substituted for the original argument key.  This eliminates the
need for any parameter key pattern matching within the C<:Init> subroutine.

C<Regexp> may be abbreviated to C<Regex> or C<Re>.

=head1 OBJECT PRE-iNITIALIZATION

Occassionally, a child class may need to send a parameter to a parent class as
part of object initialization.  This can be accomplished by supplying a
C<:PreInit> labeled subroutine in the child class.  These subroutines, if
found, are called in order from the bottom of the class hierarchy upwards
(i.e., child classes first).

The subroutine should expect two arguments:  The newly created
(un-initialized) object (i.e., C<$self>), and a hash ref of all the parameters
from the C<-E<gt>new()> method call, including any additional parameters added
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

After all the C<:PreInit> subroutines have been executed, object
initialization will then proceed using the resulting parameter hash.

=head1 ACCESSOR GENERATION

Accessors are object methods used to get data out of and put data into an
object.  You can, of course, write your own accessor code, but this can get a
bit tedious, especially if your class has lots of fields.  Object::InsideOut
provides the capability to automatically generate accessors for you.

=head2 Basic Accessors

A I<get> accessor is vary basic:  It just returns the value of an object's
field:

 my @data :Field;

 sub fetch_data
 {
     my $self = shift;
     return ($data[$$self]);
 }

and you would use it as follows:

 my $data = $obj->fetch_data();

To have Object::InsideOut generate such a I<get> accessor for you, add a
C<:Get> attribute to the field declaration, specifying the name for the
accessor in parentheses:

 my @data :Field :Get(fetch_data);

Similarly, a I<set> accessor puts data in an object's field.  The I<set>
accessors generated by Object::InsideOut check that they are called with at
least one argument.  They are specified using the C<:Set> attribute:

 my @data :Field :Set(store_data);

Some programmers use the convention of naming I<get> and I<set> accessors
using I<get_> and I<set_> prefixes.  Such I<standard> accessors can be
generated using the C<:Standard> attribute (which may be abbreviated to
C<:Std>):

 my @data :Field :Std(data);

which is equivalent to:

 my @data :Field :Get(get_data) :Set(set_data);

Other programmers perfer to use a single I<combination> accessors that
performs both functions:  When called with no arguments, it I<gets>, and when
called with an argument, it I<sets>.  Object::InsideOut will generate such
accessors with the C<:Accessor> attribute.  (This can be abbreviated to
C<:Acc>, or you can use C<:Get_Set> or C<:Combined> or C<:Combo> or even
C<Mutator>.)  For example:

 my @data :Field :Acc(data);

The generated accessor would be used in this manner:

 $obj->data($val);           # Puts data into the object's field
 my $data = $obj->data();    # Fetches the object's field data

=head2 I<Set> Accessor Return Value

For any of the automatically generated methods that perform I<set> operations,
the default for the method's return value is the value being set (i.e., the
I<new> value).

You can specify the I<set> accessor's return value using the C<Return>
attribute parameter (which may be abbreviated to C<Ret>).  For example, to
explicitly specify the default behavior use:

 my @data :Field :Set('Name' => 'store_data', 'Return' => 'New');

You can specify that the accessor should return the I<old> (previous) value
(or C<undef> if unset):

 my @data :Field :Acc('Name' => 'data', 'Ret' => 'Old');

You may use <Previous>, C<Prev> or C<Prior> as synonyms for C<Old>.

Finally, you can specify that the accessor should return the object itself:

 my @data :Field :Std('Name' => 'data', 'Ret' => 'Object');

C<Object> may be abbreviated to C<Obj>, and is also synonymous with C<Self>.

=head2 Method Chaining

An obvious case where method chaining can be used is when a field is used to
store an object:  A method for the stored object can be chained to the I<get>
accessor call that retrieves that object:

 $obj->get_stored_object()->stored_object_method()

Chaining can be done off of I<set> accessors based on their return value (see
above).  In this example with a I<set> accessor that returns the I<new> value:

 $obj->set_stored_object($stored_obj)->stored_object_method()

the I<set_stored_object()> call stores the new object, returning it as well,
and then the I<stored_object_method()> call is invoked via the stored/returned
object.  The same would work for I<set> accessors that return the I<old>
value, too, but in that case the chained method is invoked via the previously
stored (and now returned) object.

If the L<Want> module (version 0.12 or later) is available, then
Object::InsideOut also tries to do I<the right thing> with method chaining for
I<set> accessors that don't store/return objects.  In this case, the object
used to invoke the I<set> accessor will also be used to invoke the chained
method (just as though the I<set> accessor were declared with
S<C<'Return' =E<gt> 'Object'>>):

 $obj->set_data('data')->do_something();

To make use of this feature, just add C<use Want;> to the beginning of your
application.

Note, however, that this special handling does not apply to I<get> accessors,
nor to I<combination> accessors invoked without an argument (i.e., when used
as a I<get> accessor).  These must return objects in order for method chaining
to succeed.

=head2 :lvalue Accessors

As documented in L<perlsub/"Lvalue subroutines">, an C<:lvalue> subroutine
returns a modifiable value.  This modifiable value can then, for example, be
used on the left-hand side (hence C<LVALUE>) of an assignment statement, or
a substitution regular expression.

For Perl 5.8.0 and later, Object::InsideOut supports the generation of
C<:lvalue> accessors such that their use in an C<LVALUE> context will set the
value of the object's field.  Just add C<'lvalue' =E<gt> 1> to the I<set>
accessor's attribute.  (C<'lvalue'> may be abbreviated to C<'lv'>.)

Additionally, C<:Lvalue> (or its abbreviation C<:lv>) may be used for a
combined I<get/set> I<:lvalue> accessor.  In other words, the following are
equivalent:

 :Acc('Name' => 'email', 'lvalue' => 1)

 :Lvalue(email)

Here is a detailed example:

 package Contact; {
     use Object::InsideOut;

     # Create separate a get accessor and an :lvalue set accessor
     my @name  :Field
               :Get(name)
               :Set('Name' => 'set_name', 'lvalue' => 1);

     # Create a standard get_/set_ pair of accessors
     #   The set_ accessor will be an :lvalue accessor
     my @phone :Field
               :Std('Name' => 'phone', 'lvalue' => 1);

     # Create a combined get/set :lvalue accessor
     my @email :Field
               :Lvalue(email);
 }

 package main;

 my $obj = Contact->new();

 # Use :lvalue accessors in assignment statements
 $obj->set_name()  = 'Jerry D. Hedden';
 $obj->set_phone() = '800-555-1212';
 $obj->email()     = 'jdhedden AT cpan DOT org';

 # Use :lvalue accessor in substituion regexp
 $obj->email() =~ s/ AT (\w+) DOT /\@$1./;

 # Use :lvalue accessor in a 'substr' call
 substr($obj->set_phone(), 0, 3) = '888';

 print("Contact info:\n");
 print("\tName:  ", $obj->name(),      "\n");
 print("\tPhone: ", $obj->get_phone(), "\n");
 print("\tEmail: ", $obj->email(),     "\n");

The use of C<:lvalue> accessors requires the installation of the L<Want>
module (version 0.12 or later) from CPAN.  See particularly the section
L<Want/"Lvalue subroutines:"> for more information.

C<:lvalue> accessors also work like regular I<set> accessors in being able to
accept arguments, return values, and so on:

 my @pri :Field
         :Lvalue('Name' => 'priority', 'Return' => 'Old');
  ...
 my $old_pri = $obj->priority(10);

C<:lvalue> accessors can be used in L<method chains|/"Method Chaining">.

B<CAVEATS>

While still classified as I<experimental>, Perl's support for C<:lvalue>
subroutines has been around since 5.6.0, and a good number of CPAN modules
make use of them.

By definition, because C<:lvalue> accessors return the I<location> of a field,
they break encapsulation.  As a result, some OO advocates eschew the use of
C<:lvalue> accessors.

C<:lvalue> accessors are slower than corresponding I<non-lvalue> accessors.
This is due to the fact that more code is needed to handle all the diverse
ways in which C<:lvalue> accessors may be used.  (I've done my best to
optimize the generated code.)  For example, here's the code that is generated
for a simple combined accessor:

 *Foo::foo = sub {
     return ($$field[${$_[0]}]) if (@_ == 1);
     $$field[${$_[0]}] = $_[1];
 };

And the corresponding code for an C<:lvalue> combined accessor:

 *Foo::foo = sub :lvalue {
     my $rv = !Want::want_lvalue(0);
     Want::rreturn($$field[${$_[0]}]) if ($rv && (@_ == 1));
     my $assign;
     if (my @args = Want::wantassign(1)) {
         @_ = ($_[0], @args);
         $assign = 1;
     }
     if (@_ > 1) {
         $$field[${$_[0]}] = $_[1];
         Want::lnoreturn if $assign;
         Want::rreturn($$field[${$_[0]}]) if $rv;
     }
     ((@_ > 1) && (Want::wantref() eq 'OBJECT') &&
      !Scalar::Util::blessed($$field[${$_[0]}]))
            ? $_[0] : $$field[${$_[0]}];
 };

=head1 ALL-IN-ONE

Parameter naming and accessor generation may be combined:

 my @data :Field :All(data);

This is I<syntactic shorthand> for:

 my @data :Field :Arg(data) :Acc(data);

If you want the accessor to be C<:lvalue>, use:

 my @data :Field :LV_All(data);

If I<standard> accessors are desired, use:

 my @data :Field :Std_All(data);

Attribute parameters affecting the I<set> accessor may also be used.  For
example, if you want I<standard> accessors with an C<:lvalue> I<set> accessor:

 my @data :Field :Std_All('Name' => 'data', 'Lvalue' => 1);

If you want a combined accessor that returns the I<old> value on I<set>
operations:

 my @data :Field :All('Name' => 'data', 'Ret' => 'Old');

And so on.

If you need to add attribute parameters that affect the C<:Arg> portion
(e.g., 'Default', 'Mandatory', etc.), then you cannot use C<:All>.  Fall back
to using the separate attributes.  For example:

 my @data :Field :Arg('Name' => 'data', 'Mand' => 1)
                 :Acc('Name' => 'data', 'Ret' => 'Old');

=head1 PERMISSIONS

=head2 Restricted and Private Methods

Access to certain methods can be narrowed by use of the C<:Restricted> and
C<:Private> attributes.  C<:Restricted> methods can only be called from within
the class's hierarchy.  C<:Private> methods can only be called from within the
method's class.

Without the above attributes, most methods have I<public> access.  If desired,
you may explicitly label them with the C<:Public> attribute.

You can also specify access permissions on L<automatically generated
accessors|/"ACCESSOR GENERATION">:

 my @data     :Field :Std('Name' => 'data',     'Permission' => 'private');
 my @info     :Field :Set('Name' => 'set_info', 'Perm' => 'restricted');
 my @internal :Field :Acc('Name' => 'internal', 'Private' => 1);
 my @state    :Field :Get('Name' => 'state',    'Restricted' => 1);

When creating a I<standard> pair of I<get_/set_> accessors, the premission
setting is applied to both accessors.  If different permissions are required
on the two accessors, then you'll have to use separate C<:Get> and C<:Set>
attributes on the field.

 # Create a private set method
 # and a restricted get method on the 'foo' field
 my @foo :Field
         :Set('Name' => 'set_foo', 'Priv' => 1);
         :Get('Name' => 'get_foo', 'Rest' => 1);

 # Create a restricted set method
 # and a public get method on the 'bar' field
 my %bar :Field
         :Set('Name' => 'set_bar', 'Perm' => 'restrict');
         :Get(get_bar);

C<Permission> may be abbreviated to C<Perm>; C<Private> may be abbreviated to
C<Priv>; and C<Restricted> may be abbreviated to C<Restrict>.

=head2 Hidden Methods

For subroutines marked with the following attributes (most of which are
discussed later in this document):

=over

=item :ID

=item :PreInit

=item :Init

=item :Replicate

=item :Destroy

=item :Automethod

=item :Dumper

=item :Pumper

=item :MOD_*_ATTRS

=item :FETCH_*_ATTRS

=back

Object::InsideOut normally renders them uncallable (hidden) to class and
application code (as they should normally only be needed by Object::InsideOut
itself).  If needed, this behavior can be overridden by adding the C<Public>,
C<Restricted> or C<Private> attribute parameters:

 sub _init :Init(private)    # Callable from within this class
 {
     my ($self, $args) = @_;

     ...
 }

NOTE:  A bug in Perl 5.6.0 prevents using these access attribute parameters.
As such, subroutines marked with the above attributes will be left with
I<public> access.

NOTE:  The above cannot be accomplished by using the corresponding permission
attributes.  For example:

 # sub _init :Init :Private    # Wrong syntax - doesn't work

=head1 TYPE CHECKING

Object::InsideOut can be directed to add type-checking code to the
I<set/combined> accessors it generates, and to perform type checking on
object initialization parameters.

=head2 Field Type Checking

Type checking for a field can be specified by adding the C<:Type> attribute to
the field declaration:

 my @data :Field :Type(Numeric);

The C<:Type> attribute results in type checking code being added to
I<set/combined> accessors generated by Object::InsideOut, and will perform
type checking on object initialization parameters processed by the C<:Arg>
attribute.

Available Types are:

=over

=item Numeric

Can also be specified as C<Num> or C<Number>.  This uses
L<Scalar::Util::looks_like_number()|Scalar::Util/"looks_like_number EXPR"> to
test the input value.

=item List or Array

This type permits an accessor to accept multiple values (which are then
placed in an array ref) or a single array ref.

For object initialization parameters, it permits a single value (which is then
placed in an array ref) or an array ref.

=item Array_ref

This specifies that only a single array reference is permitted.  Can also be
specified as C<Arrayref>.

=item Hash

This type permits an accessor to accept multiple S<C<key =E<gt> value>> pairs
(which are then placed in a hash ref) or a single hash ref.

For object initialization parameters, only a single ref is permitted.

=item Hash_ref

This specifies that only a single hash reference is permitted.  Can also be
specified as C<Hashref>.

=item A class name

This permits only an object of the specified class, or one of its sub-classes
(i.e., type checking is done using C<-E<gt>isa()>).  For example,
C<My::Class>.

=item Other reference type

This permits only a reference of the specified type (as returned by
L<ref()|perlfunc/"ref EXPR">).  The type must be specified in all caps.
For example, C<CODE>.

=back

The C<:Type> attribute can also be supplied with a code reference to provide
custom type checking.  The code ref may either be in the form of an anonymous
subroutine, or a fully-qualified subroutine name.  The result of executing the
code ref on the input argument should be a boolean value.  Here's some
examples:

 package My::Class; {
     use Object::InsideOut;

     # Type checking using an anonymous subroutine
     #  (This checks that the argument is a scalar)
     my @data :Field :Type(sub { ! ref($_[0]) });
                     :Acc(data)

     # Type checking using a fully-qualified subroutine name
     my @num  :Field :Type(\&My::Class::positive);
                     :Acc(num)

     # The type checking subroutine may be made 'Private'
     sub positive :Private
     {
         return (Scalar::Util::looks_like_number($_[0]) &&
                 ($_[0] > 0));
     }
 }

=head2 Type Checking on C<:Init> Parameters

For object initialization parameters that are sent to the C<:Init> subroutine
during object initialization, the parameter's type can be specified in the
C<:InitArgs> hash for that parameter using the same types as specified in the
previous section.  For example:

 my %init_args :InitArgs = (
     'DATA' => {
         'Type' => 'Numeric',
     },
 );

=head1 CUMULATIVE METHODS

Normally, methods with the same name in a class hierarchy are masked (i.e.,
overridden) by inheritance - only the method in the most-derived class is
called.  With cumulative methods, this masking is removed, and the same-named
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
by class for each of the cumulative method calls.  Through overloading, this
object can then be dereferenced as an array, hash, string, number, or boolean.
For example, the above could be rewritten as:

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

As illustrated above, cumulative methods are tagged with the C<:Cumulative>
attribute (or S<C<:Cumulative(top down)>>), and propagate from the I<top down>
through the class hierarchy (i.e., from the parent classes down through the
child classes).  If tagged with S<C<:Cumulative(bottom up)>>, they will
propagated from the object's class upwards through the parent classes.

=head1 CHAINED METHODS

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

     sub format_name
     {
         my ($self, $name) = @_;

         # Attempt to properly case names
         return (nc($name));
     }
 }

And you decide that you'd like to perform some formatting of your own, and
then have all the parent methods apply their own formatting.  Normally, if you
have a single parent class, you'd just call the method directly with
C<$self-E<gt>SUPER::format_name($name)>, but if you have more than one parent
class you'd have to explicitly call each method directly:

 package Customer; {
     use Object::InsideOut qw(Person Subscriber);

     sub format_name
     {
         my ($self, $name) = @_;

         # Compress all whitespace into a single space
         $name =~ s/\s+/ /g;

         $name = $self->Subscriber::format_name($name);
         $name = $self->Person::format_name($name);

         return $name;
     }
 }

With Object::InsideOut, you'd add the C<:Chained> attribute to each class's
C<format_name> method, and the methods will be chained together automatically:

 package Subscriber; {
     use Object::InsideOut;

     sub format_name :Chained
     {
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

     sub format_name :Chained
     {
         my ($self, $name) = @_;

         # Attempt to properly case names
         return (nc($name));
     }
 }

 package Customer; {
     use Object::InsideOut qw(Person Subscriber);

     sub format_name :Chained
     {
         my ($self, $name) = @_;

         # Compress all whitespace into a single space
         $name =~ s/\s+/ /g;

         return ($name);
     }
 }

So passing in someone's name to C<format_name> in C<Customer> would cause
leading and trailing whitespace to be removed, then the name to be properly
cased, and finally whitespace to be compressed to a single space.  The
resulting C<$name> would be returned to the caller:

 my ($name) = $obj->format_name($name_raw);

Unlike C<:Cumulative> methods, C<:Chained> methods B<always> returns an array
- even if there is only one value returned.  Therefore, C<:Chained>
methods should always be called in an array context, as illustrated above.

The default direction is to chain methods from the parent classes at the top
of the class hierarchy down through the child classes.  You may use the
attribute S<C<:Chained(top down)>> to make this more explicit.

If you label the method with the S<C<:Chained(bottom up)>> attribute, then the
chained methods are called starting with the object's class and working
upwards through the parent classes in the class hierarchy, similar to how
S<C<:Cumulative(bottom up)>> works.

=head1 ARGUMENT MERGING

As mentioned under L<"OBJECT CREATION">, the C<-E<gt>new()> method can take
parameters that are passed in as combinations of S<C<key =E<gt> value>> pairs
and/or hash refs:

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

The parameters are I<merged> into a single hash ref before they are processed.

Adding the C<:MergeArgs> attribute to your methods gives them a similar
capability.  Your method will then get two arguments:  The object and a single
hash ref of the I<merged> arguments.  For example:

 package Foo; {
     use Object::InsideOut;

     ...

     sub my_method :MergeArgs {
         my ($self, $args) = @_;

         my $param = $args->{'param'};
         my $data  = $args->{'data'};
         my $flag  = $args->{'flag'};
         ...
     }
 }

 package main;

 my $obj = Foo->new(...);

 $obj->my_method( { 'data' => 42,
                    'flag' => 'true' },
                   'param' => 'foo' );

=head1 AUTOMETHODS

There are significant issues related to Perl's C<AUTOLOAD> mechanism that
cause it to be ill-suited for use in a class hierarchy. Therefore,
Object::InsideOut implements its own C<:Automethod> mechanism to overcome
these problems.

Classes requiring C<AUTOLOAD>-type capabilities must provided a subroutine
labeled with the C<:Automethod> attribute.  The C<:Automethod> subroutine
will be called with the object and the arguments in the original method call
(the same as for C<AUTOLOAD>).  The C<:Automethod> subroutine should return
either a subroutine reference that implements the requested method's
functionality, or else just end with C<return;> to indicate that it doesn't
know how to handle the request.

Using its own C<AUTOLOAD> subroutine (which is exported to every class),
Object::InsideOut walks through the class tree, calling each C<:Automethod>
subroutine, as needed, to fulfill an unimplemented method call.

The name of the method being called is passed as C<$_> instead of
C<$AUTOLOAD>, and does I<not> have the class name prepended to it.  If the
C<:Automethod> subroutine also needs to access the C<$_> from the caller's
scope, it is available as C<$CALLER::_>.

Automethods can also be made to act as L</"CUMULATIVE METHODS"> or L</"CHAINED
METHODS">.  In these cases, the C<:Automethod> subroutine should return two
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
method should not be used with C<:Cumulative> or C<:Chained> automethods.

=head1 OBJECT SERIALIZATION

=head2 Basic Serialization

=over

=item my $array_ref = $obj->dump();

=item my $string = $obj->dump(1);

Object::InsideOut exports a method called C<-E<gt>dump()> to each class that
returns either a I<Perl> or a string representation of the object that invokes
the method.

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
specified by adding the C<:Name> attribute to the field:

 my @life :Field :Name(life);

If the C<:Name> attribute is not used, then the name for a field will be
either the name associated with an C<:All> or C<:Arg> attribute, its I<get>
method name, its I<set> method name, or, failing all that, a string of the
form C<ARRAY(0x...)> or C<HASH(0x...)>.

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
the class developer must either add C<:Name> attributes to the C<:Field>
declarations (see above), or provide a C<:Dumper>/C<:Pumper> pair of
subroutines as described below.

=item C<:Dumper> Subroutine Attribute

If a class requires special processing to dump its data, then it can provide a
subroutine labeled with the C<:Dumper> attribute.  This subroutine will be
sent the object that is being dumped.  It may then return any type of scalar
the developer deems appropriate.  Usually, this would be a hash ref containing
S<C<key =E<gt> value>> pairs for the object's fields.  For example:

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
C<Object::InsideOut-E<gt>pump()>.  The subroutine will be supplied the new
object that is being created, and whatever scalar was returned by the
C<:Dumper> subroutine.  The corresponding C<:Pumper> for the example
C<:Dumper> above would be:

 sub _pump :Pumper
 {
     my ($obj, $field_data) = @_;

     $obj->set(\@data, $field_data->{'data'});
 }

=back

=head2 Storable

Object::InsideOut also supports object serialization using the L<Storable>
module.  There are two methods for specifying that a class can be serialized
using L<Storable>.  The first method involves adding L<Storable> to the
Object::InsideOut declaration in your package:

 package My::Class; {
     use Object::InsideOut qw(Storable);
     ...
 }

and adding S<C<use Storable;>> in your application.  Then you can use the
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
S<C<::storable>> variable inside a C<BEGIN> block for the class prior to its
use:

 package main;
 use Storable;

 BEGIN {
     $My::Class::storable = 1;
 }
 use My::Class;

=head1 OBJECT COERCION

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

Coercing an object to a scalar (C<:Scalarify>) is B<not> supported as C<$$obj>
is the ID of the object and cannot be overridden.

=head1 CLONING

=head2 Object Cloning

Copies of objects can be created using the C<-E<gt>clone()> method which is
exported by Object::InsideOut to each class:

 my $obj2 = $obj->clone();

When called without arguments, C<-E<gt>clone()> creates a I<shallow> copy of
the object, meaning that any complex data structures (i.e., array, hash or
scalar refs) stored in the object will be shared with its clone.

Calling C<-E<gt>clone()> with a I<true> argument:

 my $obj2 = $obj->clone(1);

creates a I<deep> copy of the object such that internally held array, hash
or scalar refs are I<replicated> and stored in the newly created clone.

I<Deep> cloning can also be controlled at the field level, and is covered in
the next section.

Note that cloning does not clone internally held objects.  For example, if
C<$foo> contains a reference to C<$bar>, a clone of C<$foo> will also contain
a reference to C<$bar>; not a clone of C<$bar>.  If such behavior is needed,
it must be provided using a L<:Replicate|/"Object Replication"> subroutine.

=head2 Field Cloning

Object cloning can be controlled at the field level such that only specified
fields are I<deeply> copied when C<-E<gt>clone()> is called without any
arguments.  This is done by adding the C<:Deep> attribute to the field:

 my @data :Field :Deep;

=head1 WEAK FIELDS

Frequently, it is useful to store L<weaken|Scalar::Util/"weaken REF">ed
references to data or objects in a field.  Such a field can be declared as
C<:Weak> so that data (i.e., references) set via Object::InsideOut generated
accessors, parameter processing using C<:Arg>, the C<-E<gt>set()> method,
etc., will automatically be L<weaken|Scalar::Util/"weaken REF">ed after being
stored in the field array/hash.

 my @data :Field :Weak;

NOTE: If data in a I<weak> field is set directly (i.e., the C<-E<gt>set()>
method is not used), then L<weaken()|Scalar::Util/"weaken REF"> must be
invoked on the stored reference afterwards:

 $field[$$self] = $data;
 Scalar::Util::weaken($field[$$self]);

(This is another reason why the C<-E<gt>set()> method is recommended for
setting field data within class code.)

=head1 DYNAMIC FIELD CREATION

Normally, object fields are declared as part of the class code.  However,
some classes may need the capability to create object fields I<on-the-fly>,
for example, as part of an C<:Automethod>.  Object::InsideOut provides a class
method for this:

 # Dynamically create a hash field with standard accessors
 My::Class->create_field('%'.$fld, ":Std($fld)");

The first argument is the class into which the field will be added.  The
second argument is a string containing the name of the field preceeded by
either a C<@> or C<%> to declare an array field or hash field, respectively.
The remaining string arguments should be attributes declaring accessors and
the like.  The C<:Field> attribute is assumed, and does not need to be added
to the attribute list.  For example:

 My::Class->create_field('@data', ":Type(numeric)",
                                  ":Acc(data)");

 My::Class->create_field('@obj', ":Type(Some::Class)",
                                 ":Acc(obj)",
                                 ":Weak");

Field creation will fail if you try to create an array field within a class
whose hierarchy has been declared L<:hash_only|/"HASH ONLY CLASSES">.

Here's an example of an C<:Automethod> subroutine that uses dynamic field
creation:

 package My::Class; {
     use Object::InsideOut;

     sub _automethod :Automethod
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
         $class->create_field('@'.$fld_name, ":Std($fld_name)");

         # Return code ref for newly created accessor
         no strict 'refs';
         return *{$class.'::'.$method}{'CODE'};
     }
 }

=head1 PREPROCESSING

=head2 Parameter Preprocessing

You can specify a code ref (either in the form of an anonymous subroutine, or
a fully-qualified subroutine name) for an object initialization parameter that
will be called on that parameter prior to taking any of the other parameter
actions described above.  Here's an example:

 package My::Class; {
     use Object::InsideOut;

     my @data :Field
              :Arg('Name' => 'DATA', 'Preprocess' => \&My::Class::preproc);

     my %init_args :InitArgs = (
         'PARAM' => {
             'Preprocess' => \&My::Class::preproc);
         },
     );

     # The parameter preprocessing subroutine may be made 'Private'
     sub preproc :Private
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

Either C<DATA> or C<PARAM> in the example above.

=item * A hash ref of the parameter's specifiers

This is either a hash ref containing the C<:Arg> attribute parameters, or the
hash ref paired to the parameter's key in the C<:InitArgs> hash.

=item * The object being initialized

=item * The parameter's value

This is the value assigned to the parameter in the C<-E<gt>new()> method's
argument list.  If the parameter was not provided to C<-E<gt>new()>, then
C<undef> will be sent.

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

I<Preprocess> may be abbreviated to I<Preproc> or I<Pre>.

=head2 I<Set> Accessor Preprocessing

You can specify a code ref (either in the form of an anonymous subroutine, or
a fully-qualified subroutine name) for a I<set/combined> accessor that will be
called on the arguments supplied to the accessor prior to its taking the usual
actions of type checking and adding the data to the field.  Here's an example:

 package My::Class; {
     use Object::InsideOut;

     my @data :Field
              :Acc('Name' => 'data', 'Preprocess' => \&My::Class::preproc);

     # The set accessor preprocessing subroutine may be made 'Private'
     sub preproc :Private
     {
         my ($self, $field, @args) = @_;

         # Preform preprocessing on the accessor's arguments
         ...

         # Return result
         return ...;
     }
 }

As the above illustrates, the accessor preprocessing subroutine is sent the
following arguments:

=over

=item * The object used to invoke the accessor

=item * A reference to the field associated with the accessor

=item * The argument(s) sent to the accessor

There will always be at least one argument.

=back

Usually, the preprocessing subroutine should return just a single value.  For
fields declared as type C<List>, multiple values may be returned.

Following preprocessing, the I<set> accessor will operate on whatever value(s)
are returned by the proprocessing subroutine.

=head1 SPECIAL PROCESSING

=head2 Object ID

By default, the ID of an object is derived from a sequence counter for the
object's class hierarchy.  This should suffice for nearly all cases of class
development.  If there is a special need for the module code to control the
object ID (see L<Math::Random::MT::Auto> as an example), then a
subroutine labelled with the C<:ID> attribute can be specified:

 sub _id :ID
 {
     my $class = $_[0];

     # Generate/determine a unique object ID
     ...

     return ($id);
 }

The ID returned by your subroutine can be any kind of I<regular> scalar (e.g.,
a string or a number).  However, if the ID is something other than a
low-valued integer, then you will have to architect B<all> your classes using
hashes for the object fields.  See L<HASH ONLY CLASSES> for details.

Within any class hierarchy, only one class may specify an C<:ID> subroutine.

=head2 Object Replication

Object replication occurs explicitly when the C<-E<gt>clone()> method is
called on an object, and implicitly when threads are created in a threaded
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

In the case of thread cloning, C<$flag> will be set to the C<'CLONE'>, and the
C<$parent> object is just an un-blessed anonymous scalar reference that
contains the ID for the object in the parent thread.

When invoked via the C<-E<gt>clone()> method, C<$flag> will be either an empty
string which denotes that a I<shallow> copy is being produced for the clone,
or C<$flag> will be set to C<'deep'> indicating a I<deep> copy is being
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

This allows you to access the foreign class's static (i.e., class) methods
from your own class.  For example, suppose C<Foreign::Class> has a class
method called C<foo>.  With the above, you can access that method using
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

a. Declare the foreign class using the standard method (i.e.,
S<C<use Object::InsideOut qw(Foreign::Class);>>), and invoke its methods using
their full path (e.g., C<$obj-E<gt>Foreign::Class::method();>); or

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
path (e.g., C<My::Class-E<gt>Foreign::Class::method();>), or you can
S<C<use base>> so that you don't have to use the full path.  Again, using the
full path is faster.

L<Class::Singleton> is an example of this type of class.

=item 3. Class methods that don't care how they are invoked (i.e., they don't
make reference to the invoking class).

In this case, you can either use
S<C<use Object::InsideOut qw(Foreign::Class);>> for consistency, or use
S<C<use base qw(Foreign::Class);>> if (slightly) better performance is needed.

=back

If you're not familiar with the inner workings of the foreign class such that
you don't know if or which of the above exceptions applies, then the formulaic
approach would be to first use the documented method for foreign inheritance
(i.e., S<C<use Object::InsideOut qw(Foreign::Class);>>).  If that works, then
I strongly recommend that you just use that approach unless you have a good
reason not to.  If it doesn't work, then try S<C<use base>>.

=head1 INTROSPECTION

Object::InsideOut provides an introspection API that allow you to obtain
metadata on a class's hierarchy, constructor parameters, and methods.

=over

=item my $meta = My::Class->meta();

=item my $meta = $obj->meta();

The C<-E<gt>meta()> method, which is exported by Object::InsideOut to each
class, returns an L<Object::InsideOut::Metadata> object which can then be
I<queried> for information about the invoking class or invoking object's
class:

 # Get an object's class hierarchy
 my @classes = $obj->meta()->get_classes();

 # Get info on the args for a class's constructor (i.e., ->new() parameters)
 my %args = My::Class->meta()->get_args();

 # Get info on the methods that can be called by an object
 my %methods = $obj->meta()->get_methods();

=item My::Class->isa();

=item $obj->isa();

When called in an array context, calling C<-E<gt>isa()> without any arguments
on an Object::InsideOut class or object returns a list of the classes in the
class hierarchy for that class or object, and is equivalent to:

 my @classes = $obj->meta()->get_classes();

When called in a scalar context, it returns an array ref containing the
classes.

=item My::Class->can();

=item $obj->can();

When called in an array context, calling C<-E<gt>can()> without any arguments
on an Object::InsideOut class or object returns a list of the method names for
that class or object, and is equivalent to:

 my %methods = $obj->meta()->get_methods();
 my @methods = keys(%methods);

When called in a scalar context, it returns an array ref containing the
method names.

=back

See L<Object::InsideOut::Metadata> for more details.

=head1 THREAD SUPPORT

For Perl 5.8.1 and later, Object::InsideOut fully supports L<threads> (i.e.,
is thread safe), and supports the sharing of Object::InsideOut objects between
threads using L<threads::shared>.

To use Object::InsideOut in a threaded application, you must put
S<C<use threads;>> at the beginning of the application.  (The use of
S<C<require threads;>> after the program is running is not supported.)  If
object sharing is to be utilized, then S<C<use threads::shared;>> should
follow.

If you just S<C<use threads;>>, then objects from one thread will be copied
and made available in a child thread.

The addition of S<C<use threads::shared;>> in and of itself does not alter the
behavior of Object::InsideOut objects.  The default behavior is to I<not>
share objects between threads (i.e., they act the same as with
S<C<use threads;>> alone).

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

The other method is for a class to add a C<:SHARED> flag to its
S<C<use Object::InsideOut ...>> declaration:

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
     my @data :Field :Type(List) :Acc(data);
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

=head1 HASH ONLY CLASSES

For performance considerations, it is recommended that arrays be used for
class fields whenever possible.  The only time when hash-bases fields are
required is when a class must provide its own L<object ID/"Object ID">, and
those IDs are something other than low-valued integers.  In this case, hashes
must be used for fields not only in the class that defines the object ID
subroutine, but also in every class in any class hierarchy that include such a
class.

The I<hash only> requirement can be enforced by adding the C<:HASH_ONLY> flag
to a class's S<C<use Object::InsideOut ...>> declaration:

 package My::Class; {
     use Object::InsideOut ':hash_only';

     ...
 }

This will cause Object::Inside to check every class in any class hierarchy
that includes such flagged classes to make sure their fields are hashes and
not arrays.  It will also fail any L<-E<gt>create_field()|/"DYNAMIC FIELD
CREATION"> call that tries to create an array-based field in any such class.

=head1 SECURITY

In the default case where Object::InsideOut provides object IDs that are
sequential integers, it is possible to I<hack together> a I<fake>
Object::InsideOut object, and so gain access to another object's data:

 my $fake = bless(\do{my $scalar}, 'Some::Class');
 $$fake = 86;   # ID of another object
 my $stolen = $fake->get_data();

Why anyone would try to do this is unknown.  How this could be used for any
sort of malicious exploitation is also unknown.  However, if preventing this
sort of I<security> issue is a requirement, it can be accomplished by giving
your objects a random ID, and thus prevent other code from creating fake
objects by I<guessing> at the IDs.

To do this, your class must provide an L<:ID subroutine|/"Object ID"> that
returns I<random values>, and the class must be flagged as L<:HASH_ONLY|/"HASH
ONLY CLASSES">.  One simple way of providing random IDs it to use random
integers provided by L<Math::Random::MT::Auto>, as illustrated below:

 package My::Class; {
     use Object::InsideOut ':HASH_ONLY';
     use Math::Random::MT::Auto 'irand';

     sub _id :ID { irand(); }

     ...
 }

=head1 ATTRIBUTE HANDLERS

Object::InsideOut uses I<attribute 'modify' handlers> as described in
L<attributes/"Package-specific Attribute Handling">, and provides a mechanism
for adding attibute handlers to your own classes.  Instead of naming your
attribute handler as C<MODIFY_*_ATTRIBUTES>, name it something else and then
label it with the C<:MODIFY_*_ATTRIBUTES> attribute (or C<:MOD_*_ATTRS> for
short).  Your handler should work just as described in
L<attributes/"Package-specific Attribute Handling"> with regard to its input
arguments, and must return a list of the attributes which were not recognized
by your handler.  Here's an example:

 package My::Class; {
     use Object::InsideOut;

     sub _scalar_attrs :MOD_SCALAR_ATTRS
     {
         my ($pkg, $scalar, @attrs) = @_;
         my @unused_attrs;         # List of any unhandled attributes

         while (my $attr = shift(@attrs)) {
             if ($attr =~ /.../) {
                 # Handle attribute
                 ...
             } else {
                 # We don't handle this attribute
                 push(@unused_attrs, $attr);
             }
         }

         return (@unused_attrs);   # Pass along unhandled attributes
     }
 }

Attribute 'modify' handlers are called I<upwards> through the class hierarchy
(i.e., I<bottom up>).  This provides child classes with the capability to
I<override> the handling of attributes by parent classes, or to add attributes
(via the returned list of unhandled attributes) for parent classes to process.

Attribute 'modify' handlers should be located at the beginning of a package,
or at least before any use of attibutes on the corresponding type of variable
or subroutine:

 package My::Class; {
     use Object::InsideOut;

     sub _array_attrs :MOD_ARRAY_ATTRS
     {
        ...
     }

     my @my_array :MyArrayAttr;
 }

For I<attribute 'fetch' handlers>, follow the same procedures:  Label the
subroutine with the C<:FETCH_*_ATTRIBUTES> attribute (or C<:FETCH_*_ATTRS> for
short).  Contrary to the documentation in L<attributes/"Package-specific
Attribute Handling">, I<attribute 'fetch' handlers> receive B<two> arguments:
The relevant package name, and a reference to a variable or subroutine for
which package-defined attributes are desired.

Attribute handlers are normal rendered L<hidden|/"Hidden Methods">.

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

Object::InsideOut uses C<Exception::Class> for reporting errors.  The base
error class for this module is C<OIO>.  Here is an example of the basic manner
for trapping and handling errors:

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

Object::InsideOut installs a C<__DIE__> handler (see L<perlfunc/"die LIST">
and L<perlfunc/"eval BLOCK">) to catch any errant exceptions from
class-specific code, namely, C<:Init>, C<:Replicate>, C<:Destroy>, etc.
subroutines.  This handler may interfer with code that uses the C<die>
function as a method of flow control for leaving an C<eval> block.  The proper
method for handling this is to localize C<$SIG{'__DIE__'}> inside the C<eval>
block:

 eval {
     local $SIG{'__DIE__'};           # Suppress any existing __DIE__ handler
     ...
     die({'found' => 1}) if $found;   # Leave the eval block
     ...
 };
 if ($@) {
     die unless (ref($@) && $@->{'found'});   # Propagate any 'real' error
     # Handle 'found' case
     ...
 }
 # Handle 'not found' case

Similarly, if calling code from other modules that work as above, but without
localizing C<$SIG{'__DIE__'}>, you can workaround this deficiency with your
own C<eval> block:

 eval {
     local $SIG{'__DIE__'};     # Suppress any existing __DIE__ handler
     Some::Module::func();      # Call function that fails to localize
 };
 if ($@) {
     # Handle caught exception
 }

In addition, you should file a bug report against the offending module along
with a patch that adds the missing S<C<local $SIG{'__DIE__'};>> statement.

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

Due to limitations in the Perl parser, the entirety of any one attribute must
be on a single line.  (However, multiple attributes may appear on separate
lines.)

If a I<set> accessor accepts scalars, then you can store any inside-out
object type in it.  If its C<Type> is set to C<HASH>, then it can store any
I<blessed hash> object.

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

 $SIG{'__WARN__'} = sub {
         if ($_[0] !~ /^Attempt to free unreferenced scalar/) {
             print(STDERR @_);
         }
     };

A better solution would be to upgrade L<threads> and L<threads::shared> from
CPAN, especially if you encounter other problems associated with threads.

For Perl 5.8.4 and 5.8.5, the L</"Storable"> feature does not work due to a
Perl bug.  Use Object::InsideOut v1.33 if needed.

L<Devel::StackTrace> (used by L<Exception::Class>) makes use of the I<DB>
namespace.  As a consequence, Object::InsideOut thinks that S<C<package DB>>
is already loaded.  Therefore, if you create a class called I<DB> that is
sub-classed by other packages, you may need to C<require> it as follows:

 package DB::Sub; {
     require DB;
     use Object::InsideOut qw(DB);
     ...
 }

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

Optionally, L<Want> for L</":lvalue Accessors">.

=head1 SEE ALSO

Object::InsideOut Discussion Forum on CPAN:
L<http://www.cpanforum.com/dist/Object-InsideOut>

Annotated POD for Object::InsideOut:
L<http://annocpan.org/~JDHEDDEN/Object-InsideOut-2.06/lib/Object/InsideOut.pm>

Inside-out Object Model:
L<http://www.perlmonks.org/?node_id=219378>,
L<http://www.perlmonks.org/?node_id=483162>,
L<http://www.perlmonks.org/?node_id=515650>,
Chapters 15 and 16 of I<Perl Best Practices> by Damian Conway

L<Object::InsideOut::Metadata>

L<Storable>, L<Exception:Class>, L<Want>, L<attributes>, L<overload>

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
