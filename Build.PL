# Module makefile for Object::InsideOut (using Module::Build)

use strict;
use warnings;

use Module::Build;


# Check for Scalar::Util::weaken()
eval { require Scalar::Util; };
if ($@) {
    # Not found - require minimum version
    $Scalar::Util::VERSION = 1.10;
} elsif (! Scalar::Util->can('weaken')) {
    # Pure Perl version only
    if ($Scalar::Util::VERSION < 1.10) {
        # Require minimum version
        $Scalar::Util::VERSION = 1.10;
    } else {
        # Require next higher version
        $Scalar::Util::VERSION += 0.01;
    }
}


# Create make file
Module::Build->new(
    'module_name' => 'Object::InsideOut',
    'license'     => 'perl',
    'dist_author' => 'Jerry D. Hedden <jdhedden AT cpan DOT org>',

    'build_requires' => {
                            'Test::More'          => 0.50,
                        },

    'requires'       => {
                            'perl'                => '5.6.0',
                            'Exception::Class'    => 1.22,
                            'attributes'          => 0,
                            'overload'            => 0,
                            'Data::Dumper'        => 0,
                            'Scalar::Util'        => $Scalar::Util::VERSION,
                        },

    'recommends'     => {
                            'Want'                => 0,
                        },

)->create_build_script();

# EOF
