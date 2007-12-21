package Bundle::Object::InsideOut;

use strict;

our $VERSION = '3.35';
$VERSION = eval $VERSION;

1;

__END__

=head1 NAME

Bundle::Object::InsideOut - A bundle of modules for full Object::InsideOut support

=head1 SYNOPSIS

 perl -MCPAN -e "install Bundle::Object::InsideOut"

=head1 CONTENTS

Test::Harness 3.05              - Used for module testing

Test::Simple 0.74               - Used for module testing

Scalar::Util 1.19               - Used by Object::InsideOut

Pod::Escapes 1.04               - Used by Pod::Simple

Pod::Simple 3.05                - Used by Test::Pod

Test::Pod 1.26                  - Checks POD syntax

Devel::Symdump 2.08             - Used by Pod::Coverage

File::Spec 3.25                 - Used by Pod::Parser

Pod::Parser 1.35                - Used by Pod::Coverage

Pod::Coverage 0.19              - Used by Test::Pod::Coverage

Test::Pod::Coverage 1.08        - Tests POD coverage

threads 1.67                    - Support for threads

threads::shared 1.15            - Support for sharing objects between threads

Want 0.16                       - :lvalue accessor support

Storable 2.18                   - Object serialization support

Devel::StackTrace 1.15          - Used by Exception::Class

Class::Data::Inheritable 0.06   - Used by Exception::Class

Exception::Class 1.23           - Error handling

Object::InsideOut 3.35          - Inside-out object support

URI 1.35                        - Used by LWP::UserAgent

HTML::Tagset 3.10               - Used by LWP::UserAgent

HTML::Parser 3.56               - Used by LWP::UserAgent

LWP::UserAgent 2.036            - Used by Math::Random::MT::Auto

Win32::API 0.46                 - Used by Math::Random::MT::Auto (Win XP only)

Math::Random::MT::Auto 6.09     - Support for :SECURE mode

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

Copyright 2006 - 2007 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
