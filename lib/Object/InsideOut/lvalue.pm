package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Create an :lvalue accessor method
sub create_lvalue_accessor
{
    if ($] < 5.008) {
        my ($pkg, $set) = @_;
        OIO::Code->die(
            'message' => "Can't create 'lvalue' accessor method '$set' for package '$pkg'",
            'Info'    => q/'lvalue' accessors require Perl 5.8.0 or later/);
    }

    eval { require Want; };
    if ($@) {
        my ($pkg, $set) = @_;
        OIO::Code->die(
            'message' => "Can't create 'lvalue' accessor method '$set' for package '$pkg'",
            'Info'    => q/Failure loading 'Want' module/,
            'Error'   => $@);
    } elsif ($Want::VERSION < 0.12) {
        my ($pkg, $set) = @_;
        OIO::Code->die(
            'message' => "Can't create 'lvalue' accessor method '$set' for package '$pkg'",
            'Info'    => q/Requires 'Want' v0.12 or later/);
    }

    *Object::InsideOut::create_lvalue_accessor = sub
    {
        my $caller = caller();
        if ($caller ne __PACKAGE__) {
            OIO::Method->die('message' => "Can't call private subroutine 'Object::InsideOut::create_lvalue_accessor' from class '$caller'");
        }

        my ($pkg, $set, $field_ref, $get, $type, $name, $return,
            $private, $restricted, $weak, $pre) = @_;

        # Field string
        my $fld_str = (ref($field_ref) eq 'HASH') ? "\$field->\{\${\$_[0]}}" : "\$field->\[\${\$_[0]}]";

        # 'Want object' string
        my $obj_str = q/(Want::wantref() eq 'OBJECT')/;

        # Begin with subroutine declaration in the appropriate package
        my $code = "*${pkg}::$set = sub :lvalue {\n"
                 . preamble_code($pkg, $set, $private, $restricted)
                 . "    my \$rv = !Want::want_lvalue(0);\n";

        # Add GET portion for combination accessor
        if ($get && ($get eq $set)) {
            $code .= "    Want::rreturn($fld_str) if (\$rv && (\@_ == 1));\n";
        }

        # If set only, then must have at least one arg
        else {
            $code .= <<"_CHECK_ARGS_";
    my \$wobj = $obj_str;
    if ((\@_ < 2) && (\$rv || \$wobj)) {
        OIO::Args->die(
            'message'  => q/Missing arg(s) to '$pkg->$set'/,
            'location' => [ caller() ]);
    }
_CHECK_ARGS_
            $obj_str = '$wobj';
        }

        # Add field locking code if sharing
        if (is_sharing($pkg)) {
            $code .= "    lock(\$field);\n"
        }

        # Return value for 'OLD'
        if ($return eq 'OLD') {
            $code .= "    my \$ret;\n";
        }

        # Get args if assignment
        $code .= <<"_SET_";
    my \$assign;
    if (my \@args = Want::wantassign(1)) {
        \@_ = (\$_[0], \@args);
        \$assign = 1;
    }
    if (\@_ > 1) {
_SET_

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
            my (\$arg, \$ok, \@errs);
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
            if ($weak) {
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

        # Grab 'OLD' value
        if ($return eq 'OLD') {
            $code .= "        \$ret = $fld_str;\n";
        }

        # Add actual 'set' code
        $code .= (is_sharing($pkg))
              ? "        $fld_str = Object::InsideOut::Util::make_shared($arg_str);\n"
              : "        $fld_str = $arg_str;\n";
        if ($weak) {
            $code .= "        Scalar::Util::weaken($fld_str);\n";
        }

        # Add code for return value
        $code     .= "        Want::lnoreturn if \$assign;\n";
        if ($return eq 'SELF') {
            $code .= "        Want::rreturn(\$_[0]) if \$rv;\n";
        } elsif ($return eq 'OLD') {
            $code .= "        Want::rreturn(\$ret) if \$rv;\n";
        } else {
            $code .= "        Want::rreturn($fld_str) if \$rv;\n";
        }
        $code .= "    }\n";

        if ($return eq 'SELF') {
            $code .= "    (\@_ < 2) ? $fld_str : \$_[0];\n";
        } elsif ($return eq 'OLD') {
            $code .= "    (\@_ < 2) ? $fld_str : (($obj_str && !Scalar::Util::blessed(\$ret)) ? \$_[0] : \$ret);\n";
        } else {
            $code .= "    ((\@_ > 1) && $obj_str && !Scalar::Util::blessed($fld_str)) ? \$_[0] : $fld_str;\n";
        }
        $code .= "};\n";

        # Done
        return ($code);
    };

    # Do the original call
    goto &create_lvalue_accessor;
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.11;
($Object::InsideOut::VERSION == 2.11) or die("Version mismatch\n");
