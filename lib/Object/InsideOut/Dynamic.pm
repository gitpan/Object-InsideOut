package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

# Dynamically create a new object field
sub create_field
{
    my ($u_isa, @args) = @_;

    *Object::InsideOut::create_field = sub
    {
        # Handle being called as a method or subroutine
        if ($_[0] eq __PACKAGE__) {
            shift;
        }

        my ($class, $field, $attr) = @_;

        # Verify valid class
        if (! $class->$u_isa(__PACKAGE__)) {
            OIO::Args->die(
                'message' => 'Not an Object::InsideOut class',
                'Arg'     => $class);
        }

        # Check for valid field
        if ($field !~ /^\s*[@%]\s*[a-zA-Z_]\w*\s*$/) {
            OIO::Args->die(
                'message' => 'Not an array or hash declaration',
                'Arg'     => $field);
        }

        # Tidy up attribute
        if ($attr) {
            $attr =~ s/^\s*:\s*Field\s*//i;         # Remove :Field
            $attr =~ s/^[(]\s*[{]?\s*//i;           # Remove ({
            $attr =~ s/\s*[}]?\s*[)]\s*[;]?\s*$//;  # Remove })
            $attr =~ s/[\r\n]/ /g;                  # Handle line-wrapping
            if ($attr) {
                $attr = "($attr)";                  # Add () if not empty string
            }
        }
        if (! $attr) {
            OIO::Args->die(
                'message' => 'Missing accessor generation parameters',
                'Usage'   => 'See POD for correct usage');
        }

        # Create the declaration
        my @errs;
        local $SIG{__WARN__} = sub { push(@errs, @_); };

        my $code = "package $class; my $field :Field$attr;";
        eval $code;
        if (my $e = Exception::Class::Base->caught()) {
            die($e);
        }
        if ($@ || @errs) {
            my ($err) = split(/ at /, $@ || join(" | ", @errs));
            OIO::Code->die(
                'message' => 'Failure creating field',
                'Error'   => $err,
                'Code'    => $code);
        }

        # Process the declaration
        process_fields();
    };


    # Do the original call
    @_ = @args;
    goto &create_field;
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 1.47;
($Object::InsideOut::VERSION == 1.47) or die("Version mismatch\n");
