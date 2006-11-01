package Bundle::Object::InsideOut;

our $VERSION = 2.18;

1;

__END__

=head1 NAME

Bundle::Object::InsideOut - A bundle of modules for full Object::InsideOut support

=head1 SYNOPSIS

 perl -MCPAN -e 'install Bundle::Object::InsideOut'

=head1 CONTENTS

Test::More 0.64                 - Used for module testing

Test::Pod 1.26                  - Checks POD syntax

Devel::Symdump 2.0604           - Used by Test::Pod::Coverage

Pod::Coverage 0.18              - Used by Test::Pod::Coverage

Test::Pod::Coverage 1.08        - Tests POD coverage

Scalar::Util 1.18               - Used by Object::InsideOut

Want 0.12                       - :lvalue accessor support

Storable 2.15                   - Object serialization support

LWP::UserAgent 2.033            - Used by Math::Random::MT::Auto

Win32::API 0.41                 - Used by Math::Random::MT::Auto (Win32 only)

threads 1.47                    - Support for threads

threads::shared 1.05            - Support for sharing objects between threads

Devel::StackTrace 1.13          - Used by Exception::Class

Class::Data::Inheritable 0.06   - Used by Exception::Class

Exception::Class 1.23           - Error handling

Object::InsideOut 2.18          - Inside-out object support

Math::Random::MT::Auto 5.04     - Support for :SECURE mode

=head1 DESCRIPTION

This bundle includes all the modules used to test and support
Object::InsideOut.

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
