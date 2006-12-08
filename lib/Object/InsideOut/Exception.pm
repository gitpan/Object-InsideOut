package Object::InsideOut::Exception; {

use strict;
use warnings;

our $VERSION = 3.04;

# Exceptions generated by this module
use Exception::Class (
    'OIO' => {
        'description' => 'Generic Object::InsideOut exception',
        # First 3 fields must be:  'Package', 'File', 'Line'
        'fields' => ['Error', 'Chain'],
    },

    'OIO::Code' => {
        'isa' => 'OIO',
        'description' =>
            'Object::InsideOut exception that indicates a coding error',
        'fields' => ['Info', 'Code'],
    },

    'OIO::Internal' => {
        'isa' => 'OIO::Code',
        'description' =>
            'Object::InsideOut exception that indicates a internal problem',
        'fields' => ['Code', 'Declaration'],
    },

    'OIO::Attribute' => {
        'isa' => 'OIO::Code',
        'description' =>
            'Object::InsideOut exception that indicates a coding error',
        'fields' => ['Attribute'],
    },

    'OIO::Method' => {
        'isa' => 'OIO',
        'description' =>
            'Object::InsideOut exception that indicates an method calling error',
    },

    'OIO::Args' => {
        'isa' => 'OIO::Method',
        'description' =>
            'Object::InsideOut exception that indicates an argument error',
        'fields' => ['Usage', 'Arg'],
    },
);


# Turn on stack trace by default
OIO->Trace(1);


# A 'throw' method that adds location information to the exception object
sub OIO::die
{
    my $class = shift;
    my %args  = @_;

    # Report on ourself?
    my $report_self = delete($args{'self'});

    # Ignore ourselves in stack trace, unless told not to
    if (! $report_self) {
        my @ignore = (__PACKAGE__, 'Object::InsideOut');
        if (exists($args{'ignore_package'})) {
            if (ref($args{'ignore_package'})) {
                push(@ignore, @{$args{'ignore_package'}});
            } else {
                push(@ignore, $args{'ignore_package'});
            }
        }
        $args{'ignore_package'} = \@ignore;
    }

    # Remove any location information
    my $location = delete($args{'location'});

    # Create exception object
    my $e = $class->new(%args);

    # Override location information, if applicable
    if ($location) {
        $e->{'package'} = $$location[0];
        $e->{'file'}    = $$location[1];
        $e->{'line'}    = $$location[2];
    }

    # If reporting on ourself, then correct location info
    elsif ($report_self) {
        my $frame = $e->trace->frame(1);
        $e->{'package'} = $frame->package;
        $e->{'line'}    = $frame->line;
        $e->{'file'}    = $frame->filename;
    }

    # Throw error
    $e->throw(%args);
}


# Provides a fully formated error message for the exception object
sub OIO::full_message
{
    my $self = shift;

    # Start with error class and message
    my $msg = ref($self) . ' error: ' . $self->message();
    chomp($msg);

    # Add fields, if any
    my @fields = $self->Fields();
    foreach my $field (@fields) {
        next if ($field eq 'Chain');
        if (exists($self->{$field})) {
            $msg .= "\n$field: " . $self->{$field};
            chomp($msg);
        }
    }

    # Add location
    $msg .= "\nPackage: " . $self->{'package'}
          . "\nFile: "    . $self->{'file'}
          . "\nLine: "    . $self->{'line'};

    # Chained error messages
    if (exists($self->{'Chain'})) {
        my $chain = OIO::full_message($self->{'Chain'});
        chomp($chain);
        $chain =~ s/^/    /mg;
        $msg .= "\n\nSubsequent to the above, the following error also occurred:\n"
              . $chain;
    }

    return ($msg . "\n");
}


# Catch untrapped errors
# Usage:  local $SIG{'__DIE__'} = 'OIO::trap';
sub OIO::trap
{
    # Just rethrow if already an exception object
    if (Object::InsideOut::Util::is_it($_[0], 'Exception::Class::Base')) {
        die($_[0]);
    }

    # Package the error into an object
    OIO->die(
        'location' => [ caller() ],
        'message'  => 'Trapped uncaught error',
        'Error'    => join('', @_));
}


# Combine errors into a single error object
sub OIO::combine
{
    my ($err1, $err2) = @_;

    # Massage second error, if needed
    if ($err2 && ! ref($err2)) {
        my $e = OIO->new(
            'message'  => "$err2",
            'ignore_package' => [ __PACKAGE__ ]
        );

        my $frame = $e->trace->frame(1);
        $e->{'package'} = $frame->package;
        $e->{'line'}    = $frame->line;
        $e->{'file'}    = $frame->filename;

        $err2 = $e;
    }

    # Massage first error, if needed
    if ($err1) {
        if (! ref($err1)) {
            my $e = OIO->new(
                'message'  => "$err1",
                'ignore_package' => [ __PACKAGE__ ]
            );

            my $frame = $e->trace->frame(1);
            $e->{'package'} = $frame->package;
            $e->{'line'}    = $frame->line;
            $e->{'file'}    = $frame->filename;

            $err1 = $e;
        }

        # Combine errors, if possible
        if ($err2) {
            if (Object::InsideOut::Util::is_it($err1, 'OIO')) {
                $err1->{'Chain'} = $err2;
            } else {
                warn($err2);   # Can't combine
            }
        }

    } else {
        $err1 = $err2;
        undef($err2);
    }

    return ($err1);
}

}  # End of package's lexical scope

1;
