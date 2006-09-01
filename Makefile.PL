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


# Construct make file
WriteMakefile(
    'NAME'          => 'Object::InsideOut',
    'AUTHOR'        => 'Jerry D. Hedden <jdhedden AT cpan DOT org>',
    'VERSION_FROM'  => 'lib/Object/InsideOut.pm',
    'ABSTRACT_FROM' => 'lib/Object/InsideOut.pm',
    'PREREQ_PM'     => { 'Exception::Class' => 1.22,
                         'Test::More'       => 0.50,
                         'attributes'       => 0,
                         'overload'         => 0,
                         'B'                => 0,
                         'Data::Dumper'     => 0,
                         'Scalar::Util'     => $Scalar::Util::VERSION,
                       },
    ((ExtUtils::MakeMaker->VERSION() lt '6.25') ?
        ('PL_FILES' => { })            : ()),
    ((ExtUtils::MakeMaker->VERSION() gt '6.30') ?
        ('LICENSE'  => 'perl')         : ()),
);


# Add additional targets to Makefile for use by module maintainer
sub MY::postamble
{
    if ($^O eq 'cygwin') {
        return <<'_EXTRAS_';
# Check version strings in various files
vcheck:
	@echo "Version is $(VERSION)"
	@if ! head -3 Changes | tail -1 | grep ^$(VERSION) >/dev/null; then echo "Version error in Changes"; fi
	@if ! head -1 README | grep $(VERSION)$ >/dev/null; then echo "Version error in README"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in InsideOut.pm"; fi
	@if ! grep "Exception $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in InsideOut.pm"; fi
	@if ! grep "Util $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in InsideOut.pm"; fi
	@if ! grep "version $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in POD of InsideOut.pm"; fi
	@if ! grep "Object-InsideOut-$(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in Anno link in InsideOut.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/attributes.pm >/dev/null; then echo "Version error in attributes.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/attributes.pm >/dev/null; then echo "Version error in attributes.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Autoload.pm >/dev/null; then echo "Version error in Autoload.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Autoload.pm >/dev/null; then echo "Version error in Autoload.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Chained.pm >/dev/null; then echo "Version error in Chained.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Chained.pm >/dev/null; then echo "Version error in Chained.pm"; fi
	@if ! grep "InsideOut $(VERSION)" lib/Object/InsideOut/Cumulative.pm >/dev/null; then echo "Version error in Cumulative.pm"; fi
	@if ! grep 'our $$VERSION = $(VERSION)' lib/Object/InsideOut/Cumulative.pm >/dev/null; then echo "Version error in Cumulative.pm"; fi
	@if ! grep 'my $$VERSION = $(VERSION)' lib/Object/InsideOut/Cumulative.pm >/dev/null; then echo "Version error in Cumulative.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Cumulative.pm >/dev/null; then echo "Version error in Cumulative.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Dump.pm >/dev/null; then echo "Version error in Dump.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Dump.pm >/dev/null; then echo "Version error in Dump.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Dynamic.pm >/dev/null; then echo "Version error in Dynamic.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Dynamic.pm >/dev/null; then echo "Version error in Dynamic.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Exception.pm >/dev/null; then echo "Version error in Exception.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Foreign.pm >/dev/null; then echo "Version error in Foreign.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Foreign.pm >/dev/null; then echo "Version error in Foreign.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Overload.pm >/dev/null; then echo "Version error in Overload.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Overload.pm >/dev/null; then echo "Version error in Overload.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Universal.pm >/dev/null; then echo "Version error in Universal.pm"; fi
	@if ! grep "VERSION == $(VERSION)" lib/Object/InsideOut/Universal.pm >/dev/null; then echo "Version error in Universal.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Util.pm >/dev/null; then echo "Version error in lib/Object/InsideOut/Util.pm"; fi

chmod:
	@$(CHMOD) 644 Build.PL `cat MANIFEST`
_EXTRAS_
    }
}

# EOF
