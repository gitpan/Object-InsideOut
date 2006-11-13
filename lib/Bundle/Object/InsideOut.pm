package Bundle::Object::InsideOut;

use strict;

our $VERSION = 2.21;

1;

__END__

=head1 NAME

Bundle::Object::InsideOut - A bundle of modules for full Object::InsideOut support

=head1 SYNOPSIS

 perl -MCPAN -e "install Bundle::Object::InsideOut"

=head1 CONTENTS

Test::Harness 2.64              - Used for module testing

Test::More 0.65                 - Used for module testing

Scalar::Util 1.18               - Used by Object::InsideOut

Pod::Escapes 1.04               - Used by Pod::Simple

Pod::Simple 3.04                - Used by Test::Pod

Test::Pod 1.26                  - Checks POD syntax

Devel::Symdump 2.0604           - Used by Pod::Coverage

File::Spec 3.23                 - Used by Pod::Parser

Pod::Parser 1.35                - Used by Pod::Coverage

Pod::Coverage 0.18              - Used by Test::Pod::Coverage

Test::Pod::Coverage 1.08        - Tests POD coverage

threads 1.48                    - Support for threads

threads::shared 1.05            - Support for sharing objects between threads

Want 0.12                       - :lvalue accessor support

Storable 2.15                   - Object serialization support

Devel::StackTrace 1.13          - Used by Exception::Class

Class::Data::Inheritable 0.06   - Used by Exception::Class

Exception::Class 1.23           - Error handling

Object::InsideOut 2.21          - Inside-out object support

URI 1.35                        - Used by LWP::UserAgent

HTML::Tagset 3.10               - Used by LWP::UserAgent

HTML::Parser 3.55               - Used by LWP::UserAgent

LWP::UserAgent 2.033            - Used by Math::Random::MT::Auto

Win32::API 0.41                 - Used by Math::Random::MT::Auto (Win XP only)

Math::Random::MT::Auto 5.04     - Support for :SECURE mode

=head1 DESCRIPTION

This bundle includes all the modules used to test and support
Object::InsideOut.

=head1 CAVEATS

For ActivePerl on Win XP, if L<Win32::API> doesn't install using CPAN, then
try installing it using PPM:

 ppm install Win32-API

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
