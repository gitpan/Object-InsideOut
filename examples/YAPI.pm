package Term::YAPI; {
    use strict;
    use warnings;


    my $threaded_okay;   # Can we do indicators using threads?
    BEGIN {
        eval {
            require threads;
            die if ($threads::VERSION lt '1.31');
        };
        $threaded_okay = !$@;
    }

    use Object::InsideOut 2.02;

    # Default progress indicator is a twirling bar
    my @yapi
        :Field
        :Type(List)
        :Arg('Name' => 'yapi', 'Regex' => qr/^(?:yapi|prog)/i, 'Default' => [ qw(/ - \ |) ]);

    # Boolean - indicator is asynchronous?
    my @is_async
        :Field
        :Arg('Name' => 'async', 'Regex' => qr/^(?:async|thr)/i, 'Default' => 0);

    # Step counter for indicator
    my @step
        :Field
        :Arg('Name' => 'step', 'Default' => 0);

    # Boolean - indicator is running?
    my @is_running :Field;


    my $current;   # Currently running indicator
    my $sig_int;   # Remembers existing $SIG{'INT'} handler
    my $queue;     # Shared queue for communicating with indicator thread


    # Terminal control code sequences
    my $HIDE = "\e[?25l";   # Hide cursor
    my $SHOW = "\e[?25h";   # Show cursor
    my $EL   = "\e[K";      # Erase line

    sub import
    {
        my $class = shift;   # Not used

        # Don't use terminal control code sequences for MSDOS console
        if (@_ && $_[0] =~ /(?:ms|win|dos)/i) {
            ($HIDE, $SHOW, $EL) = ('', '', (' 'x40)."\r");
        }
    }


    # Initialize a new indicator object
    sub init :Init
    {
        my ($self, $args) = @_;

        # If this is the first async indicator, create the indicator thread
        if ($is_async[$$self] && ! $queue && $threaded_okay) {
            my $thr;
            eval {
                # Create communication queue for indicator thread
                require Thread::Queue;
                if ($queue = Thread::Queue->new()) {
                    # Create indicator thread in 'void' context
                    # Give the thread the queue
                    $thr = threads->create({'void' => 1}, 'yapi_thread', $queue);
                }
            };
            # If all is well, detach the thread
            if ($thr) {
                $thr->detach();
            } else {
                # Bummer :(  Can't do async indicators.
                undef($queue);
                $threaded_okay = 0;
            }
        }
    }


    # Start the indicator
    sub start
    {
        my $self = shift;
        my $msg  = shift || 'Working: ';

        $| = 1;   # Autoflush

        # Stop currently running indicator
        if ($current) {
            $current->done();
        }

        # Set ourself as running
        $is_running[$$self] = 1;
        $current = $self;

        # Remember existing interrupt handler
        $sig_int = $SIG{'INT'};

        # Set interrupt handler
        $SIG{'INT'} = sub {
            $self->done('INTERRUPTED');   # Stop the progress indicator
            kill(shift, $$);              # Propagate the signal
        };

        # Print message and hide cursor
        print("\r$EL$msg $HIDE");

        # Set up progress
        if ($is_async[$$self]) {
            if ($threaded_okay) {
                $queue->enqueue('', @{$yapi[$$self]});
                threads->yield();
            } else {
                print('wait...  ');   # Use this when 'async is broken'
            }
        } else {
            $self->progress();
        }
    }


    # Print out next progress character
    sub progress
    {
        my $self = shift;
        if ($is_running[$$self]) {
            print("\b$yapi[$$self][$step[$$self]++ % @{$yapi[$$self]}]");
        } else {
            # Not running, or some other indicator is running.
            # Therefore, start this indicator.
            $self->start();
        }
    }


    # Stop the indicator
    sub done
    {
        my $self = shift;
        my $msg  = shift || 'done';

        # Ignore if not running
        return if (! delete($is_running[$$self]));

        # No longer currently running indicator
        undef($current);

        # Halt indicator thread, if applicable
        if ($is_async[$$self] && $threaded_okay) {
            eval { $queue->enqueue(''); };
            threads->yield();
            sleep(1);
        }

        # Display done message and restore cursor
        print("\b$msg$SHOW\n");

        # Restore any previous interrupt handler
        $SIG{'INT'} = $sig_int || 'DEFAULT';
        undef($sig_int);
    }


    # Ensure indicator is stopped when indicator object is destroyed
    sub destroy :Destroy
    {
        my $self = shift;
        $self->done();
    }


    # Progress indicator thread entry point function
    sub yapi_thread :Private
    {
        my $queue = shift;

        while (1) {
            # Wait for start
            my $item;
            while (! $item) {
                $item = $queue->dequeue();
            }

            # Gather progress characters
            my @yapi = ($item);
            while ($item = $queue->dequeue_nb()) {
                push(@yapi, $item);
            }

            $| = 1;   # Autoflush

            # Show progress
            for (my ($step, $max) = (0, scalar(@yapi));
                 ! defined($item = $queue->dequeue_nb());
                 $step++)
            {
                print("\b$yapi[$step % $max]");
                sleep(1);
            }
        }
    }
}

1;

__END__

=head1 NAME

Term::YAPI - Yet Another Progress Indicator

=head1 SYNOPSIS

 use Term::YAPI;

 # Synchronous progress indicator
 my $yapi = Term::YAPI->new('yapi' => [ qw(/ - \ |) ]);
 $yapi->start('Working: ');
 foreach (1..10) {
     sleep(1);
     $yapi->progress();
 }
 $yapi->done('done');

 # Asynchronous (threaded) progress indicator
 my $yapi = Term::YAPI->new('async' => 1);
 $yapi->start('Please wait: ');
 sleep(10);
 $yapi->done('done');

=head1 DESCRIPTION

Term::YAPI provides a simple progress indicator on the terminal to let the
user know that something is happening.  The indicator is an I<animation> of
single characters displayed cyclically one after the next.

The text cursor is I<hidden> while progress is being displayed, and restored
after the progress indicator finishes.  A C<$SIG{'INT'}> handler is installed
while progress is being displayed so that the text cursor is automatically
restored should the user hit C<ctrl-C>.

The progress indicator can be controlled synchronously by the application, or
can run asynchronously in a thread.

=over

=item my $yapi = Term::YAPI->new()

Creates a new synchronous progress indicator object, using the default
I<twirling bar> indicator: / - \ |

=item my $yapi = Term::YAPI->new('yapi' => $indicator_array_ref)

Creates a new synchronous progress indicator object using the characters
specified in the supplied array ref.  Examples:

 my $yapi = Term::YAPI->new('yapi' => [ qw(^ > v <) ]);

 my $yapi = Term::YAPI->new('yapi' => [ qw(. o O o) ]);

 my $yapi = Term::YAPI->new('yapi' => [ qw(. : | :) ]);

 my $yapi = Term::YAPI->new('yapi' => [ qw(9 8 7 6 5 4 3 2 1 0) ]);

=item my $yapi = Term::YAPI->new('async' => 1);

=item my $yapi = Term::YAPI->new('yapi' => $indicator_array_ref, 'async' => 1)

Creates a new asynchronous progress indicator object.

=item $yapi->start($start_msg)

Sets up the interrupt signal handler, hides the text cursor, and prints out
the optional message string followed by the first progress character.  The
message defaults to 'Working: '.

For an asynchronous progress indicator, the progress characters begin
displaying at one second intervals.

=item $yapi->progress()

Backspaces over the previous progress character, and displays the next
character.

This method is not used with asynchronous progress indicators.

=item $yapi->done($done_msg)

Prints out the optional message (defaults to 'done'), restores the text
cursor, and removes the interrupt handler installed by the C<-E<gt>start()>
method (restoring any previous interrupt handler).

=back

The progress indicator object is reusable.

=head1 INSTALLATION

The following will install YAPI.pm under the F<Term> directory in your Perl
installation:

 cp YAPI.pm `perl -MConfig -e'print $Config{privlibexp}'`/Term/

=head1 LIMITATIONS

Works, as is, on C<xterm>, C<rxvt>, and the like.  When used with MSDOS
consoles, you need to add the C<:MSDOS> flag to the module declaration line:

 use Term::YAPI ':MSDOS';

When used as such, the text cursor will not be hidden when progress is being
displayed.

Generating multiple progress indicator objects and running them at different
times in an application is supported.  This module will not allow more than
one indicator to run at the same time.

Trying to use asynchronous progress indicators on non-threaded Perls will
work, but will not display an animated progress character.

=head1 SEE ALSO

L<Object::InsideOut>, L<threads>, L<Thread::Queue>

=head1 AUTHOR

Jerry D. Hedden, S<E<lt>jdhedden AT cpan DOT orgE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright 2005, 2006 Jerry D. Hedden. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
