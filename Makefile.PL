# Module makefile for Object::InsideOut (using ExtUtils::MakeMaker)

require 5.006;

use strict;
use warnings;

use ExtUtils::MakeMaker;
use Config;

# Check for Scalar::Util
eval { require Scalar::Util; };
if ($@) {
    # Missing
    print <<'_MISSING_';

Scalar::Util not found!  It is strongly recommended that you download
the lastest version of the Scalar-List-Utils module from CPAN.

_MISSING_

} elsif (! Scalar::Util->can('weaken')) {
    print <<'_WEAK_';

Locally installed version of Scalar::Util does not support weakened
references.  It is strongly recommended that you download the lastest version
of the Scalar-List-Utils module from CPAN, and attempt to remedy this
deficiency.  View this module's documentation for further information.

_WEAK_

} elsif ($Scalar::Util::VERSION < 1.17) {
    # Old version
    print <<'_OLD_VERSION_';

Locally installed version of Scalar::Util is out-of-date.  It is strongly
recommended that you download the lastest version of the Scalar-List-Utils
module from CPAN.

_OLD_VERSION_
}

# Construct make file
WriteMakefile(
    'NAME'          => 'Object::InsideOut',
    'AUTHOR'        => 'Jerry D. Hedden <jdhedden AT 1979 DOT usna DOT com>',
    'VERSION_FROM'  => 'lib/Object/InsideOut.pm',
    'ABSTRACT_FROM' => 'lib/Object/InsideOut.pm',
    'PREREQ_PM'     => { 'Exception::Class' => 1.22,
                         'Test::More'       => 0 },
    (($ExtUtils::MakeMaker::VERSION < 6.25) ?
        ('PL_FILES' => { })            : ()),
    (($ExtUtils::MakeMaker::VERSION > 6.30) ?
        ('LICENSE'  => 'perl')         : ()),
);


# Add additional targets to Makefile for use by module maintainer
sub MY::postamble
{
    if (exists($Config{'osname'}) && $Config{'osname'} eq 'cygwin') {
        return <<'_EXTRAS_';
# Check version strings in various files
vcheck:
	@echo "Version is $(VERSION)"
	@if ! head -3 Changes | tail -1 | grep ^$(VERSION) >/dev/null; then echo "Version error in Changes"; fi
	@if ! head -1 README | grep $(VERSION)$ >/dev/null; then echo "Version error in README"; fi
	@if ! grep "VERSION = '$(VERSION)'" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in lib/Object/InsideOut.pm"; fi
	@if ! grep "version $(VERSION)" lib/Object/InsideOut.pm >/dev/null; then echo "Version error in POD of lib/Object/InsideOut.pm"; fi
	@if ! grep "VERSION = '$(VERSION)'" lib/Object/InsideOut/Util.pm >/dev/null; then echo "Version error in lib/Object/InsideOut/Util.pm"; fi
	@if ! grep "VERSION = '$(VERSION)'" lib/Object/InsideOut/Cumulative.pm >/dev/null; then echo "Version error in lib/Object/InsideOut/Cumulative.pm"; fi

chmod:
	@$(CHMOD) 644 Build.PL `cat MANIFEST`
_EXTRAS_
    }
}

# EOF
