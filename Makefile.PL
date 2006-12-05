# Module makefile for Object::InsideOut (using ExtUtils::MakeMaker)

require 5.006;

use strict;
use warnings;

use ExtUtils::MakeMaker;


# Check for Scalar::Util::weaken()
eval { require Scalar::Util; };
if ($@) {
    # Not found - require minimum version
    $Scalar::Util::VERSION = 1.10;
} elsif (! Scalar::Util->can('weaken')) {
    # Scalar::Util is 'pure Perl' version
    if ($Scalar::Util::VERSION eq '1.18') {
        die <<_NO_WEAKEN_;
You must reinstall Scalar::Util in order to install Object::InsideOut
because the currently installed Scalar::Util is a 'pure perl' version
that is missing the 'weaken()' function.
_NO_WEAKEN_
    }
    if ($Scalar::Util::VERSION lt '1.10') {
        # Require minimum version
        $Scalar::Util::VERSION = 1.10;
    } else {
        # Require next higher version
        $Scalar::Util::VERSION += 0.01;
    }
}


# Check for Want module
eval { require Want; };
if ($@) {
    print(<<_WANT_);

Checking prerequisites...
 * Optional prerequisite Want is not installed

ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions
of the modules indicated above before proceeding with this installation

_WANT_
} elsif ($Want::VERSION < 0.12) {
    print(<<_WANT_);

Checking prerequisites...
 * Want ($Want::VERSION) is installed, but we prefer to have 0.12 or later

ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions
of the modules indicated above before proceeding with this installation

_WANT_
}


# Check for MRMA
eval { require Math::Random::MT::Auto; };
if ($@) {
    print(<<_MRMA_);

Checking prerequisites...
 * Optional prerequisite Math::Random::MT::Auto is not installed

ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions
of the modules indicated above before proceeding with this installation

_MRMA_
} elsif ($Math::Random::MT::Auto::VERSION < 5.04) {
    print(<<_MRMA_);

Checking prerequisites...
 * Math::Random::MT::Auto ($Math::Random::MT::Auto::VERSION) is installed, but we prefer to have 5.04 or later

ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions
of the modules indicated above before proceeding with this installation

_MRMA_
}


# Construct make file
WriteMakefile(
    'NAME'          => 'Object::InsideOut',
    'AUTHOR'        => 'Jerry D. Hedden <jdhedden AT cpan DOT org>',
    'VERSION_FROM'  => 'lib/Object/InsideOut.pm',
    'ABSTRACT_FROM' => 'lib/Object/InsideOut.pod',
    'PREREQ_PM'     => { 'strict'           => 0,
                         'warnings'         => 0,
                         'attributes'       => 0,
                         'overload'         => 0,
                         'Config'           => 0,
                         'B'                => 0,
                         'Data::Dumper'     => 0,
                         'Scalar::Util'     => $Scalar::Util::VERSION,
                         'Exception::Class' => 1.22,
                         'Test::More'       => 0.50,
                       },
    ((ExtUtils::MakeMaker->VERSION() lt '6.25')
                              ? ('PL_FILES' => { })    : ()),
    ((ExtUtils::MakeMaker->VERSION() gt '6.30')
                              ? ('LICENSE'  => 'perl') : ()),
);


# Add additional targets to Makefile for use by module maintainer
sub MY::postamble
{
    if ($^O eq 'cygwin') {
        return <<'_EXTRAS_';
misc:
	@$(CHMOD) 644 Build.PL `cat MANIFEST`
	@dos2unix `cat MANIFEST`
_EXTRAS_
    }
}

# EOF
