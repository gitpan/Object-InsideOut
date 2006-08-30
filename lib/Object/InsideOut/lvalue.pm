package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Create an :lvalue accessor method
sub create_lvalue_accessor
{
    if ($] < 5.008) {
        my ($package, $set) = @_;
        OIO::Code->die(
            'message' => "Can't create 'lvalue' accessor method '$set' for package '$package'",
            'Info'    => q/'lvalue' accessors require Perl 5.8.0 or later/);
    }

    *Object::InsideOut::create_lvalue_accessor = sub
    {
        my $caller = caller();
        if ($caller ne __PACKAGE__) {
            OIO::Method->die('message' => "Can't call private subroutine 'Object::InsideOut::create_lvalue_accessor' from class '$caller'");
        }

        my ($package, $set, $field_ref, $get, $type, $name, $return,
            $private, $restricted, $weak) = @_;

        # Field string
        my $fld_str = (ref($field_ref) eq 'HASH') ? "\$\$field\{\${\$_[0]}}" : "\$\$field\[\${\$_[0]}]";

        # Begin with subroutine declaration in the appropriate package
        my $pcode = preamble_code($package, $set, $private, $restricted);
        my $code .= <<"_START_";
*${package}::$set = sub :lvalue {
$pcode    my \$rvalue = Want::want('RVALUE');
    my \$lv_assign = Want::want('LVALUE', 'ASSIGN');
    my \$want_obj = Want::want('OBJECT');
_START_

        # Add GET portion for combination accessor
        if (defined($get) && $get eq $set) {
            $code .= "    Want::rreturn($fld_str) if (\$rvalue && \@_ == 1);\n";
        }

        # Else check that set was called with at least one arg
        else {
            $code .= <<"_CHECK_ARGS_";
    if ((\@_ < 2) && (\$rvalue || (!\$lv_assign && \$want_obj))) {
        OIO::Args->die(
            'message'  => q/Missing arg(s) to '$package->$set'/,
            'location' => [ caller() ]);
    }
_CHECK_ARGS_
        }

        # Return value for 'OLD'
        if ($return eq 'OLD') {
            $code .= "    my \$ret;\n";
        }

        # Start 'set' code
        $code .= <<"_SET_";
    if (\$lv_assign || \@_ > 1) {
        my \@args;
        if (\$lv_assign) {
            (\@args) = Want::want('ASSIGN');
        } else {
            \@args = \@_;
            shift(\@args);
        }
_SET_

        # Add data type checking
        if (ref($type)) {
            $code .= <<"_CODE_";
        my (\$arg, \$ok, \@errs);
        local \$SIG{'__WARN__'} = sub { push(\@errs, \@_); };
        eval { \$ok = \$type->(\$arg = \$args[0]) };
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
            if ($weak) {
                $code .= <<"_WEAK_";
        my \$arg;
        if (! ref(\$arg = \$args[0])) {
            OIO::Args->die(
                'message'  => "Bad argument: \$arg",
                'Usage'    => q/Argument to '$package->$set' must be a reference/,
                'location' => [ caller() ]);
        }
_WEAK_
            } else {
                # No data type check required
                $code .= "        my \$arg = \$args[0];\n";
            }

        } elsif ($type eq 'NUMERIC') {
            # One numeric argument
            $code .= <<"_NUMERIC_";
        my \$arg;
        if (! Scalar::Util::looks_like_number(\$arg = \$args[0])) {
            OIO::Args->die(
                'message'  => "Bad argument: \$arg",
                'Usage'    => q/Argument to '$package->$set' must be numeric/,
                'location' => [ caller() ]);
        }
_NUMERIC_

        } elsif ($type eq 'ARRAY') {
            # List/array - 1+ args or array ref
            $code .= <<'_ARRAY_';
        my $arg = (@args == 1 && ref($args[0]) eq 'ARRAY') ? $args[0] : \@args;
_ARRAY_

        } elsif ($type eq 'HASH') {
            # Hash - pairs of args or hash ref
            $code .= <<"_HASH_";
        my \$arg;
        if (\@args == 1 && ref(\$args[0]) eq 'HASH') {
            \$arg = \$args[0];
        } elsif (\@args % 2 == 1) {
            OIO::Args->die(
                'message'  => q/Odd number of arguments: Can't create hash ref/,
                'Usage'    => q/'$package->$set' requires a hash ref or an even number of args (to make a hash ref)/,
                'location' => [ caller() ]);
        } else {
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
        if (! Object::InsideOut::Util::is_it(\$arg = \$args[0], '$type')) {
            OIO::Args->die(
                'message'  => q/Bad argument: Wrong type/,
                'Usage'    => q/Argument to '$package->$set' must be of type '$type'/,
                'location' => [ caller() ]);
        }
_REF_
        }

        # Grab 'OLD' value
        if ($return eq 'OLD') {
            $code .= "        \$ret = $fld_str;\n";
        }

        # Add actual 'set' code
        $code .= (is_sharing($package))
              ? "        $fld_str = Object::InsideOut::Util::make_shared(\$arg);\n"
              : "        $fld_str = \$arg;\n";
        if ($weak) {
            $code .= "        Scalar::Util::weaken($fld_str);\n";
        }

        # Add code for return value
        $code     .= "        Want::lnoreturn if \$lv_assign;\n";
        if ($return eq 'SELF') {
            $code .= "        Want::rreturn(\$_[0]) if \$rvalue;\n";
        } elsif ($return eq 'OLD') {
            $code .= "        Want::rreturn(\$ret) if \$rvalue;\n";
        } else {
            $code .= "        Want::rreturn($fld_str) if \$rvalue;\n";
        }
        $code .= "    }\n";

        if ($return eq 'SELF') {
            $code .= "    (\@_ < 2) ? $fld_str : \$_[0];\n";
        } elsif ($return eq 'OLD') {
            $code .= "    (\@_ < 2) ? $fld_str : ((Want::want('OBJECT') && !Scalar::Util::blessed(\$ret)) ? \$_[0] : \$ret);\n";
        } else {
            $code .= "    ((\@_ > 1) && Want::want('OBJECT') && !Scalar::Util::blessed($fld_str)) ? \$_[0] : $fld_str;\n";
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
my $VERSION = 1.51;
($Object::InsideOut::VERSION == 1.51) or die("Version mismatch\n");
