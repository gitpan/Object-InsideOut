package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

sub install_ATTRIBUTES
{
    my ($ATTR_HANDLERS, $TREE_BOTTOM_UP) = @_;

    *Object::InsideOut::MODIFY_SCALAR_ATTRIBUTES = sub
    {
        my ($pkg, $scalar, @attrs) = @_;

        # Call attribute handlers in the class tree
        if (exists($$ATTR_HANDLERS{'MOD'}{'SCALAR'})) {
            @attrs = CHECK_ATTRS('SCALAR', $pkg, $scalar, @attrs);
        }

        # If using Attribute::Handlers, send it any unused attributes
        if (@attrs &&
            Attribute::Handlers::UNIVERSAL->can('MODIFY_SCALAR_ATTRIBUTES'))
        {
            return (Attribute::Handlers::UNIVERSAL::MODIFY_SCALAR_ATTRIBUTES($pkg, $scalar, @attrs));
        }

        # Return any unused attributes
        return (@attrs);
    };

    *Object::InsideOut::CHECK_ATTRS = sub
    {
        my ($type, $pkg, $ref, @attrs) = @_;

        # Call attribute handlers in the class tree
        foreach my $class (@{$$TREE_BOTTOM_UP{$pkg}}) {
            if (my $handler = $$ATTR_HANDLERS{'MOD'}{$type}{$class}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
                @attrs = $handler->($pkg, $ref, @attrs);
                return if (! @attrs);
            }
        }

        return (@attrs);   # Return remaining attributes
    };

    *Object::InsideOut::FETCH_ATTRS = sub
    {
        my ($type, $stash, $ref) = @_;
        my @attrs;

        # Call attribute handlers in the class tree
        if (exists($$ATTR_HANDLERS{'FETCH'}{$type})) {
            foreach my $handler (@{$$ATTR_HANDLERS{'FETCH'}{$type}}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
                push(@attrs, $handler->($stash, $ref));
            }
        }

        return (@attrs);
    };

    # Stub ourself out
    *Object::InsideOut::install_ATTRIBUTES = sub { };
}

sub FETCH_SCALAR_ATTRIBUTES { return (FETCH_ATTRS('SCALAR', @_)); }
sub FETCH_HASH_ATTRIBUTES   { return (FETCH_ATTRS('HASH',   @_)); }
sub FETCH_ARRAY_ATTRIBUTES  { return (FETCH_ATTRS('ARRAY',  @_)); }
sub FETCH_CODE_ATTRIBUTES   { return (FETCH_ATTRS('CODE',   @_)); }

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.02;
($Object::InsideOut::VERSION == 2.02) or die("Version mismatch\n");
