package Object::InsideOut; {

use strict;
use warnings;
no warnings 'redefine';

sub generate_OVERLOAD :Sub(Private)
{
    my ($OVERLOAD, $TREE_TOP_DOWN) = @_;

    # Overload specifiers
    my %TYPE = (
        'STRINGIFY' => q/""/,
        'NUMERIFY'  => q/0+/,
        'BOOLIFY'   => q/bool/,
        'ARRAYIFY'  => q/@{}/,
        'HASHIFY'   => q/%{}/,
        'GLOBIFY'   => q/*{}/,
        'CODIFY'    => q/&{}/,
    );

    foreach my $pkg (keys(%{$OVERLOAD})) {
        my %meta;
        # Generate code string
        my $code = "package $pkg;\nuse overload (\n";
        while (my $operation = shift(@{$$OVERLOAD{$pkg}})) {
            my ($attr, $ref, $location) = @$operation;
            my $name = sub_name($ref, ":$attr", $location);
            $code .= sprintf('q/%s/ => sub { $_[0]->%s() },', $TYPE{$attr}, $name) . "\n";
            $meta{$name}{'kind'} = 'overload';
        }
        $code .= q/'fallback' => 1);/;

        # Eval the code string
        my @errs;
        local $SIG{'__WARN__'} = sub { push(@errs, @_); };
        eval $code;
        if ($@ || @errs) {
            my ($err) = split(/ at /, $@ || join(" | ", @errs));
            OIO::Internal->die(
                'message'  => "Failure creating overloads for class '$pkg'",
                'Error'    => $err,
                'Code'     => $code,
                'self'     => 1);
        }

        add_meta($pkg, \%meta);
    }

    no strict 'refs';

    foreach my $pkg (keys(%{$TREE_TOP_DOWN})) {
        # Bless an object into every class
        # This works around an obscure 'overload' bug reported against
        # Class::Std (http://rt.cpan.org/NoAuth/Bug.html?id=14048)
        bless(\do{ my $scalar; }, $pkg);

        # Verify that scalar dereferencing is not overloaded in any class
        if (exists(${$pkg.'::'}{'(${}'})) {
            (my $file = $pkg . '.pm') =~ s/::/\//g;
            OIO::Code->die(
                'location' => [ $pkg, $INC{$file} || '', '' ],
                'message'  => q/Overloading scalar dereferencing '${}' is not allowed/,
                'Info'     => q/The scalar of an object is its object ID, and can't be redefined/);
        }
    }
}

}  # End of package's lexical scope


# Ensure correct versioning
my $VERSION = 2.04;
($Object::InsideOut::VERSION == 2.04) or die("Version mismatch\n");
