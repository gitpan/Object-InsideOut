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

        my ($class, $field, @attrs) = @_;
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

        # Convert attributes to single string
        my $attr;
        if (@attrs) {
            s/^\s*(.*?)\s*$/$1/ foreach @attrs;
            $attr = join(',', @attrs);
            $attr =~ s/[\r\n]/ /sg;
            $attr =~ s/,\s*,/,/g;
            $attr =~ s/\)\s*,\s*:/) :/g;
            if ($attr !~ /^\s*:/) {
                $attr = ":Field($attr)";
            }
        } else {
            $attr = ':Field';
        }

        # Create the declaration
        my @errs;
        local $SIG{'__WARN__'} = sub { push(@errs, @_); };

        my $code = "package $class; my $field $attr;";

        # Inspect generated code
        print("\n", $code, "\n\n") if $Object::InsideOut::DEBUG;

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
my $VERSION = 2.03;
($Object::InsideOut::VERSION == 2.03) or die("Version mismatch\n");
