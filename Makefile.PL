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
    # Pure Perl version only
    if ($Scalar::Util::VERSION < 1.10) {
        # Require minimum version
        $Scalar::Util::VERSION = 1.10;
    } else {
        # Require next higher version
        $Scalar::Util::VERSION += 0.01;
    }
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
                         'Data::Dumper'     => 0,
                         'Scalar::Util'     => $Scalar::Util::VERSION,
                       },
    ((ExtUtils::MakeMaker->VERSION() < 6.25) ?
        ('PL_FILES' => { })            : ()),
    ((ExtUtils::MakeMaker->VERSION() > 6.30) ?
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
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in lib/Object/InsideOut.pm"; fi
	@if ! grep "version $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in POD of lib/Object/InsideOut.pm"; fi
	@if ! grep "Object-InsideOut-$(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in Anno link in lib/Object/InsideOut.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Util.pm >/dev/null; then echo "Version error in lib/Object/InsideOut/Util.pm"; fi
	@if ! grep "VERSION = $(VERSION)" lib/Object/InsideOut/Results.pm >/dev/null; then echo "Version error in lib/Object/InsideOut/Results.pm"; fi

chmod:
	@$(CHMOD) 644 Build.PL `cat MANIFEST`
_EXTRAS_
    }
}

# EOF
