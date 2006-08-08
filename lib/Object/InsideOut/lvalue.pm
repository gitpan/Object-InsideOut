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

    eval { require Want; };
    if ($@) {
        my ($package, $set) = @_;
        OIO::Code->die(
            'message' => "Can't create 'lvalue' accessor method '$set' for package '$package'",
            'Info'    => q/Failure loading 'Want' module/,
            'Error'   => $@);
    }

    *Object::InsideOut::create_lvalue_accessor = sub
    {
        my $caller = caller();
        if ($caller ne __PACKAGE__) {
            OIO::Method->die('message' => "Can't call private subroutine 'Object::InsideOut::create_lvalue_accessor' from class '$caller'");
        }

        my ($package, $set, $field_ref, $get, $type, $name, $return,
            $private, $restricted, $weak) = @_;

        # Begin with subroutine declaration in the appropriate package
        my $code .= "*${package}::$set = sub :lvalue {\n"

                  . preamble_code($package, $set, $private, $restricted);

        # Add GET portion for combination accessor
        if (defined($get) && $get eq $set) {
            if (ref($field_ref) eq 'HASH') {
                $code .= <<"_COMBINATION_";
    my \$rvalue = Want::want('RVALUE');
    if (\$rvalue && \@_ == 1) {
        Want::rreturn (\$\$field\{\${\$_[0]}});
    }
_COMBINATION_
            } else {
                $code .= <<"_COMBINATION_";
    my \$rvalue = Want::want('RVALUE');
    if (\$rvalue && \@_ == 1) {
        Want::rreturn (\$\$field\[\${\$_[0]}]);
    }
_COMBINATION_
            }
        }

        # Else check that set was called with at least one arg
        else {
            $code .= <<"_CHECK_ARGS_";
    my \$rvalue = Want::want('RVALUE');
    if (\$rvalue && \@_ < 2) {
        OIO::Args->die(
            'message'  => q/Missing arg(s) to '$package->$set'/,
            'location' => [ caller() ]);
    }
_CHECK_ARGS_
        }

        # Start 'set' code
        $code .= <<"_SET_";
    my \$lvalue = Want::want('LVALUE', 'ASSIGN');
    if (\$lvalue || \@_ > 1) {
        my \@args;
        if (\$lvalue) {
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
        local \$SIG{__WARN__} = sub { push(\@errs, \@_); };
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
            if (ref($field_ref) eq 'HASH') {
                $code .= "        my \$ret = \$\$field\{\${\$_[0]}};\n";
            } else {
                $code .= "        my \$ret = \$\$field\[\${\$_[0]}];\n";
            }
        }

        # Add actual 'set' code
        if (ref($field_ref) eq 'HASH') {
            $code .= (is_sharing($package))
                  ? "        \$\$field\{\${\$_[0]}} = Object::InsideOut::Util::make_shared(\$arg);\n"
                  : "        \$\$field\{\${\$_[0]}} = \$arg;\n";
            if ($weak) {
                $code .= "        Scalar::Util::weaken(\$\$field\{\${\$_[0]}});\n";
            }
        } else {
            $code .= (is_sharing($package))
                  ? "        \$\$field\[\${\$_[0]}] = Object::InsideOut::Util::make_shared(\$arg);\n"
                  : "        \$\$field\[\${\$_[0]}] = \$arg;\n";
            if ($weak) {
                $code .= "        Scalar::Util::weaken(\$\$field\[\${\$_[0]}]);\n";
            }
        }

        # Add code for return value
        $code     .= "        Want::lnoreturn if \$lvalue;\n";
        if ($return eq 'SELF') {
            $code .= "        Want::rreturn \$_[0]  if \$rvalue;\n";
        } elsif ($return eq 'OLD') {
            $code .= "        Want::rreturn \$ret if \$rvalue;\n";
        } elsif (ref($field_ref) eq 'HASH') {
            $code .= "        Want::rreturn \$\$field\{\${\$_[0]}} if \$rvalue;\n";
        } else {
            $code .= "        Want::rreturn \$\$field\[\${\$_[0]}] if \$rvalue;\n";
        }
        $code .= "    }\n";
        if (ref($field_ref) eq 'HASH') {
            $code .= "    \$\$field\{\${\$_[0]}};\n";
        } else {
            $code .= "    \$\$field\[\${\$_[0]}];\n";
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
my $VERSION = 1.49;
($Object::InsideOut::VERSION == 1.49) or die("Version mismatch\n");
