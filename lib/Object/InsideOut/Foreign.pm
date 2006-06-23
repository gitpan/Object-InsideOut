package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Installs foreign inheritance methods
sub inherit
{
    my ($u_isa, $HERITAGE, $DUMP_FIELDS, $FIELDS,
        $call, @args) = @_;

    *Object::InsideOut::inherit = sub
    {
        my $self = shift;

        # Must be called as an object method
        my $obj_class = Scalar::Util::blessed($self);
        if (! $obj_class) {
            OIO::Code->die(
                'message'  => '->inherit() invoked as a class method',
                'Info'     => '->inherit() is an object method');
        }

        # Inheritance takes place in caller's package
        my $package = caller();

        # Restrict usage to inside class hierarchy
        if (! $obj_class->$u_isa($package)) {
            OIO::Code->die(
                'message'  => '->inherit() not called within class hierarchy',
                'Info'     => '->inherit() is a restricted method');
        }

        # Flatten arg list
        my @arg_objs;
        while (my $arg = shift) {
            if (ref($arg) eq 'ARRAY') {
                push(@arg_objs, @{$arg});
            } else {
                push(@arg_objs, $arg);
            }
        }

        # Must be called with at least one arg
        if (! @arg_objs) {
            OIO::Args->die('message'  => q/Missing arg(s) to '->inherit()'/);
        }

        # Get 'heritage' field and 'classes' hash
        if (! exists($$HERITAGE{$package})) {
            create_heritage($package);
        }
        my ($heritage, $classes) = @{$$HERITAGE{$package}};

        # Process args
        my $objs = exists($$heritage{$$self}) ? $$heritage{$$self} : [];
        while (my $obj = shift(@arg_objs)) {
            # Must be an object
            my $arg_class = Scalar::Util::blessed($obj);
            if (! $arg_class) {
                OIO::Args->die('message'  => q/Arg to '->inherit()' is not an object/);
            }
            # Must not be in class hierarchy
            if ($obj_class->$u_isa($arg_class) ||
                $arg_class->$u_isa($obj_class))
            {
                OIO::Args->die('message'  => q/Args to '->inherit()' cannot be within class hierarchy/);
            }
            # Add arg to object list
            push(@{$objs}, $obj);
            # Add arg class to classes hash
            $$classes{$arg_class} = undef;
        }
        # Add objects to heritage field
        $self->set($heritage, $objs);
    };


    *Object::InsideOut::heritage = sub
    {
        my $self = shift;

        # Must be called as an object method
        my $obj_class = Scalar::Util::blessed($self);
        if (! $obj_class) {
            OIO::Code->die(
                'message'  => '->inherit() invoked as a class method',
                'Info'     => '->inherit() is an object method');
        }

        # Inheritance takes place in caller's package
        my $package = caller();

        # Restrict usage to inside class hierarchy
        if (! $obj_class->$u_isa($package)) {
            OIO::Code->die(
                'message'  => '->inherit() not called within class hierarchy',
                'Info'     => '->inherit() is a restricted method');
        }

        # Anything to return?
        if (! exists($$HERITAGE{$package}) ||
            ! exists($$HERITAGE{$package}[0]{$$self}))
        {
            return (undef);
        }

        my @objs;
        if (@_) {
            # Filter by specified classes
            @objs = grep {
                        my $obj = $_;
                        grep { ref($obj) eq $_ } @_
                    } @{$$HERITAGE{$package}[0]{$$self}};
        } else {
            # Return entire list
            @objs = @{$$HERITAGE{$package}[0]{$$self}};
        }

        # Return results
        if (wantarray()) {
            return (@objs);
        }
        if (@objs == 1) {
            return ($objs[0]);
        }
        return (\@objs);
    };


    *Object::InsideOut::disinherit = sub
    {
        my $self = shift;

        # Must be called as an object method
        my $class = Scalar::Util::blessed($self);
        if (! $class) {
            OIO::Code->die(
                'message'  => '->disinherit() invoked as a class method',
                'Info'     => '->disinherit() is an object method');
        }

        # Disinheritance takes place in caller's package
        my $package = caller();

        # Restrict usage to inside class hierarchy
        if (! $class->$u_isa($package)) {
            OIO::Code->die(
                'message'  => '->disinherit() not called within class hierarchy',
                'Info'     => '->disinherit() is a restricted method');
        }

        # Flatten arg list
        my @args;
        while (my $arg = shift) {
            if (ref($arg) eq 'ARRAY') {
                push(@args, @{$arg});
            } else {
                push(@args, $arg);
            }
        }

        # Must be called with at least one arg
        if (! @args) {
            OIO::Args->die('message' => q/Missing arg(s) to '->disinherit()'/);
        }

        # Get 'heritage' field
        if (! exists($$HERITAGE{$package})) {
            OIO::Code->die(
                'message'  => 'Nothing to ->disinherit()',
                'Info'     => "Class '$package' is currently not inheriting from any foreign classes");
        }
        my $heritage = $$HERITAGE{$package}[0];

        # Get inherited objects
        my @objs = exists($$heritage{$$self}) ? @{$$heritage{$$self}} : ();

        # Check that object is inheriting all args
        foreach my $arg (@args) {
            if (Scalar::Util::blessed($arg)) {
                # Arg is an object
                if (! grep { $_ == $arg } @objs) {
                    my $arg_class = ref($arg);
                    OIO::Args->die(
                        'message'  => 'Cannot ->disinherit()',
                        'Info'     => "Object is not inheriting from an object of class '$arg_class' inside class '$class'");
                }
            } else {
                # Arg is a class
                if (! grep { ref($_) eq $arg } @objs) {
                    OIO::Args->die(
                        'message'  => 'Cannot ->disinherit()',
                        'Info'     => "Object is not inheriting from an object of class '$arg' inside class '$class'");
                }
            }
        }

        # Delete args from object
        my @new_list = ();
        OBJECT:
        foreach my $obj (@objs) {
            foreach my $arg (@args) {
                if (Scalar::Util::blessed($arg)) {
                    if ($obj == $arg) {
                        next OBJECT;
                    }
                } else {
                    if (ref($obj) eq $arg) {
                        next OBJECT;
                    }
                }
            }
            push(@new_list, $obj);
        }

        # Set new object list
        if (@new_list) {
            $self->set($heritage, \@new_list);
        } else {
            # No objects left
            delete($$heritage{$$self});
        }
    };


    *Object::InsideOut::create_heritage = sub
    {
        # Private
        my $caller = caller();
        if ($caller ne __PACKAGE__) {
            OIO::Method->die('message' => "Can't call private subroutine 'Object::InsideOut::create_heritage' from class '$caller'");
        }

        my $package = shift;

        # Check if 'heritage' already exists
        if (exists($$DUMP_FIELDS{$package}{'heritage'})) {
            OIO::Attribute->die(
                'message' => "Can't inherit into '$package'",
                'Info'    => "'heritage' already specified for another field using '$$DUMP_FIELDS{$package}{'heritage'}[1]'");
        }

        # Create the heritage field
        my $heritage = {};

        # Share the field, if applicable
        if (is_sharing($package)) {
            threads::shared::share($heritage)
        }

        # Save the field's ref
        push(@{$$FIELDS{$package}}, $heritage);

        # Save info for ->dump()
        $$DUMP_FIELDS{$package}{'heritage'} = [ $heritage, 'Inherit' ];

        # Save heritage info
        $$HERITAGE{$package} = [ $heritage, {} ];

        # Set up UNIVERSAL::can/isa to handle foreign inheritance
        install_UNIVERSAL();
    };


    # Do the original call
    @_ = @args;
    goto &$call;
}

}  # End of package's lexical scope


# Ensure correct versioning
($Object::InsideOut::VERSION == 1.43) or die("Version mismatch\n");
