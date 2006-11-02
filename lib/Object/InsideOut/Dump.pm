package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Installs object dumper and loader methods
sub dump
{
    my ($DUMP_INITARGS, $DUMP_FIELDS, $DUMPERS, $PUMPERS,
        $INIT_ARGS, $TREE_TOP_DOWN, $FIELDS, $WEAK, $call, @args) = @_;

    *Object::InsideOut::dump = sub
    {
        my $self = shift;

        # Extract field info from any :InitArgs hashes
        while (my $pkg = shift(@{$DUMP_INITARGS})) {
            INIT_ARGS:
            foreach my $name (keys(%{$$INIT_ARGS{$pkg}})) {
                my $val = $$INIT_ARGS{$pkg}{$name};
                if (ref($val) eq 'HASH') {
                    if (my $field = Object::InsideOut::Util::hash_re($val, qr/^FIELD$/i)) {
                        # Override get/set names, but not 'Name'
                        foreach my $name2 (keys(%{$$DUMP_FIELDS{$pkg}})) {
                            my $fld_spec = $$DUMP_FIELDS{$pkg}{$name2};
                            if ($field == $$fld_spec[0]) {
                                if ($$fld_spec[1] eq 'Name') {
                                    next INIT_ARGS;
                                }
                                delete($$DUMP_FIELDS{$pkg}{$name2});
                                last;
                            }
                        }
                        if (exists($$DUMP_FIELDS{$pkg}{$name}) &&
                            $field != $$DUMP_FIELDS{$pkg}{$name}[0])
                        {
                            OIO::Code->die(
                                'message' => 'Cannot dump object',
                                'Info'    => "In class '$pkg', '$name' refers to two different fields set by 'InitArgs' and '$$DUMP_FIELDS{$pkg}{$name}[1]'");
                        }
                        $$DUMP_FIELDS{$pkg}{$name} = [ $field, 'InitArgs' ];
                    }
                }
            }
        }

        # Must call ->dump() as an object method
        if (! Scalar::Util::blessed($self)) {
            OIO::Method->die('message' => q/'dump' called as a class method/);
        }

        # Gather data from the object's class tree
        my %dump;
        foreach my $pkg (@{$$TREE_TOP_DOWN{ref($self)}}) {
            # Try to use a class-supplied dumper
            if (my $dumper = $$DUMPERS{$pkg}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
                $dump{$pkg} = $self->$dumper();

            } elsif ($$FIELDS{$pkg}) {
                # Dump the data ourselves from all known class fields
                my @fields = @{$$FIELDS{$pkg}};

                # Fields for which we have names
                foreach my $name (keys(%{$$DUMP_FIELDS{$pkg}})) {
                    my $field = $$DUMP_FIELDS{$pkg}{$name}[0];
                    if (ref($field) eq 'HASH') {
                        if (exists($$field{$$self})) {
                            $dump{$pkg}{$name} = $$field{$$self};
                        }
                    } else {
                        if (exists($$field[$$self])) {
                            $dump{$pkg}{$name} = $$field[$$self];
                        }
                    }
                    if ($$WEAK{$field} && exists($dump{$pkg}{$name})) {
                        Scalar::Util::weaken($dump{$pkg}{$name});
                    }
                    @fields = grep { $_ != $field } @fields;
                }

                # Fields for which names are not known
                foreach my $field (@fields) {
                    if (ref($field) eq 'HASH') {
                        if (exists($$field{$$self})) {
                            $dump{$pkg}{$field} = $$field{$$self};
                        }
                    } else {
                        if (exists($$field[$$self])) {
                            $dump{$pkg}{$field} = $$field[$$self];
                        }
                    }
                    if ($$WEAK{$field} && exists($dump{$pkg}{$field})) {
                        Scalar::Util::weaken($dump{$pkg}{$field});
                    }
                }
            }
        }

        # Package up the object's class and its data
        my $output = [ ref($self), \%dump ];

        # Create a string version of dumped data if arg is true
        if ($_[0]) {
            require Data::Dumper;
            $output = Data::Dumper::Dumper($output);
            chomp($output);
            $output =~ s/^.{8}//gm;   # Remove initial 8 chars from each line
            $output =~ s/;$//s;       # Remove trailing semi-colon
        }

        # Done - send back the dumped data
        return ($output);
    };


    *Object::InsideOut::pump = sub
    {
        my $input = shift;

        # Check usage
        if ($input) {
            if ($input eq __PACKAGE__) {
                $input = shift;    # Called as a class method

            } elsif (Scalar::Util::blessed($input)) {
                OIO::Method->die('message' => q/'pump' called as an object method/);
            }
        }

        # Must have an arg
        if (! $input) {
            OIO::Args->die('message' => 'Missing argument to pump()');
        }

        # Convert string input to array ref, if needed
        if (! ref($input)) {
            my @errs;
            local $SIG{'__WARN__'} = sub { push(@errs, @_); };

            my $array_ref;
            eval "\$array_ref = $input";

            if ($@ || @errs) {
                my ($err) = split(/ at /, $@ || join(" | ", @errs));
                OIO::Args->die(
                    'message'  => 'Failure converting dump string back to hash ref',
                    'Error'    => $err,
                    'Arg'      => $input);
            }

            $input = $array_ref;
        }

        # Check input
        if (ref($input) ne 'ARRAY') {
            OIO::Args->die('message'  => 'Argument to pump() is not an array ref');
        }

        # Extract class name and object data
        my ($class, $dump) = @{$input};
        if (! defined($class) || ref($dump) ne 'HASH') {
            OIO::Args->die('message'  => 'Argument to pump() is invalid');
        }

        # Create a new 'bare' object
        my $self = _obj($class);

        # Store object data
        foreach my $pkg (keys(%{$dump})) {
            my $data = $$dump{$pkg};

            # Try to use a class-supplied pumper
            if (my $pumper = $$PUMPERS{$pkg}) {
                local $SIG{'__DIE__'} = 'OIO::trap';
                $self->$pumper($data);

            } else {
                # Pump in the data ourselves
                foreach my $fld_name (keys(%{$data})) {
                    my $value = $$data{$fld_name};
                    if (my $field = $$DUMP_FIELDS{$pkg}{$fld_name}[0]) {
                        $self->set($field, $value);
                    } else {
                        if ($fld_name =~ /^(?:HASH|ARRAY)/) {
                            OIO::Args->die(
                                'message' => "Unnamed field encounted in class '$pkg'",
                                'Arg'     => "$fld_name => $value");
                        } else {
                            OIO::Args->die(
                                'message' => "Unknown field name for class '$pkg': $fld_name");
                        }
                    }
                }
            }
        }

        # Done - return the object
        return ($self);
    };


    # Do the original call
    @_ = @args;
    goto &$call;
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.19;
($Object::InsideOut::VERSION == 2.19) or die("Version mismatch\n");
