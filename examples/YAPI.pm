package Term::YAPI; {
    use strict;
    use warnings;

    use Object::InsideOut 2.02;

    # Default progress indicator is a twirling bar
    my @prog  :Field
              :Type(List)
              :Arg('Name' => 'prog', 'Re' => qr/.+/, 'Def' => [ qw(/ - \ |) ]);

    my @count :Field;

    my $sig_int;

    sub start
    {
        my $self = shift;
        my $msg  = shift || 'Working: ';

        set_sig_int();
        $| = 1;                  # Autoflush
        print("$msg \e[?25l");   # Print 'msg' and hide cursor
        $self->progress();
    }

    sub progress
    {
        my $self = shift;
        # Print out next progress character
        print("\b", $prog[$$self][$count[$$self]++ % @{$prog[$$self]}]);
    }

    sub done
    {
        my $self = shift;
        my $msg  = shift || 'done';

        # Display 'msg' and restore cursor
        print("\b$msg\e[?25h\n");

        # Restore any previous interrupt handler
        $SIG{'INT'} = $sig_int || 'DEFAULT';
        undef($sig_int);
    }

    sub set_sig_int
    {
        # Remember existing interrupt handler
        $sig_int ||= $SIG{'INT'};

        # Set our interrupt handler
        $SIG{'INT'} = sub {
            # Restore cursor
            print("\e[?25h");
            # Restore any previous interrupt handler
            $SIG{'INT'} = $sig_int || 'DEFAULT';
            undef($sig_int);
            # Propagate the signal
            kill(shift, $$);
        };
    }
}

1;


__END__

=head1 NAME

Term::YAPI - Yet Another Progress Indicator

=head1 SYNOPSIS

 use Term::YAPI;

 my $prog = Term::YAPI->new('prog' => [ qw(/ - \ |) ]);

 $prog->start('Working: ');
 foreach (1..10) {
     sleep(1);
     $prog->progress();
 }
 $prog->done('done');

=head1 DESCRIPTION

Term::YAPI provides a simple progress indicator on the terminal to let the
user know that something is happening.  The indicator is an I<animation> of
single characters displayed cyclically one after the next.

The cursor is I<hidden> while progress is being displayed, and restored after
the progress indicator finishes.  A C<$SIG{'INT'}> handler is installed while
progress is being displayed so that the cursor is automatically restored
should the user hit C<ctrl-C>.

=over

=item my $prog = Term::YAPI->new()

Creates a new progress indicator object, using the default I<twirling bar>
indicator: / - \ |

=item my $prog = Term::YAPI->new('prog' => $indicator_array_ref)

Creates a new progress indicator object using the characters specified in
the supplied array ref.  Examples:

 my $prog = Term::YAPI->new('prog' => [ qw(^ > v <) ]);

 my $prog = Term::YAPI->new('prog' => [ qw(. o O o) ]);

 my $prog = Term::YAPI->new('prog' => [ qw(. : | :) ]);

 my $prog = Term::YAPI->new('prog' => [ qw(9 8 7 6 5 4 3 2 1 0) ]);

=item $prog->start($start_msg)

Sets up the interrupt signal handler, hides the cursor, and prints out the
optional message string followed by the first progress character.  The message
defaults to 'Working: '.

=item $prog->progress()

Backspaces over the previous progress character, and displays the next
character.

=item $prog->done($done_msg)

Prints out the optional message (defaults to 'done'), restores the cursor, and
removes the interrupt handler installed by the C<start> method (restoring any
previous interrupt handler).

=back

The progress indicator object is reusable.

=head1 INSTALLATION

The following will install YAPI.pm under the I<Term> directory in your Perl
installation:

 cp YAPI.pm `perl -MConfig -e'print $Config{privlibexp}'`/Term/

=head1 SEE ALSO

L<Object::InsideOut>

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2005, 2006 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
