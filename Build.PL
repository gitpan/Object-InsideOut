# Module makefile for Object::InsideOut (using Module::Build)

use strict;
use warnings;

use Module::Build;

# Create make file
Module::Build->new(
    'module_name' => 'Object::InsideOut',
    'license'     => 'perl',
    'dist_author' => 'Jerry D. Hedden <jdhedden AT 1979 DOT usna DOT com>',

    'build_requires' => {
                            'Test::More'          => 0,
                        },

    'requires'       => {
                            'perl'                => '5.6.0',
                            'Exception::Class'    => 1.22,
                            'attributes'          => 0,
                            'overload'            => 0,
                            'Data::Dumper'        => 0
                        },
    'recommends'     => {
                            'Scalar::Util'        => 1.17,
                        },

)->create_build_script();

# EOF
