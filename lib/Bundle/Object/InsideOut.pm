package Bundle::Object::InsideOut;

use strict;
use warnings;

our $VERSION = '3.88';
$VERSION = eval $VERSION;

1;

__END__

=head1 NAME

Bundle::Object::InsideOut - A bundle of modules for full Object::InsideOut support

=head1 SYNOPSIS

 perl -MCPAN -e "install Bundle::Object::InsideOut"

=head1 CONTENTS

Test::Harness 3.23              - Used for module testing

Test::Simple 0.98               - Used for module testing

Scalar::Util 1.23               - Used by Object::InsideOut

Pod::Escapes 1.04               - Used by Pod::Simple

Pod::Simple 3.19                - Used by Test::Pod

Test::Pod 1.45                  - Checks POD syntax

Devel::Symdump 2.08             - Used by Pod::Coverage

File::Spec 3.33                 - Used by Pod::Parser

Pod::Parser 1.51                - Used by Pod::Coverage

Pod::Coverage 0.21              - Used by Test::Pod::Coverage

Test::Pod::Coverage 1.08        - Tests POD coverage

threads 1.86                    - Support for threads

threads::shared 1.40            - Support for sharing objects between threads

Want 0.18                       - :lvalue accessor support

Data::Dumper 2.131              - Object serialization support

Storable 2.30                   - Object serialization support

Devel::StackTrace 1.27          - Used by Exception::Class

Class::Data::Inheritable 0.08   - Used by Exception::Class

Exception::Class 1.32           - Error handling

Object::InsideOut 3.88          - Inside-out object support

URI 1.59                        - Used by LWP::UserAgent

HTML::Tagset 3.20               - Used by LWP::UserAgent

HTML::Parser 3.69               - Used by LWP::UserAgent

LWP::UserAgent 6.03             - Used by Math::Random::MT::Auto

Win32::API 0.64                 - Used by Math::Random::MT::Auto (Win XP only)

Math::Random::MT::Auto 6.18     - Support for :SECURE mode

=head1 DESCRIPTION

This bundle includes all the modules used to test and support
Object::InsideOut.

=head1 CAVEATS

For ActivePerl on Win XP, if L<Win32::API> doesn't install using CPAN, then
try installing it using PPM:

 ppm install Win32-API

Obviously, Win32::API will not install on all platforms - just Windows and
Cygwin.

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 - 2012 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
