package Mojo::Exception;
use Mojo::Base -base;
use overload bool => sub {1}, '""' => sub { shift->to_string }, fallback => 1;

use Exporter 'import';
use Mojo::Util 'decode';
use Scalar::Util 'blessed';

has [qw(frames line lines_after lines_before)] => sub { [] };
has message                                    => 'Exception!';
has 'verbose';

our @EXPORT_OK = ('check');

sub check {
  my ($err, @spec) = @_ % 2 ? @_ : ($@, @_);

  # Finally (search backwards since it is usually at the end)
  my $guard;
  for (my $i = $#spec - 1; $i >= 0; $i -= 2) {
    next unless $spec[$i] eq 'finally';
    $guard = Mojo::Exception::_Guard->new(finally => $spec[$i + 1]);
    last;
  }

  return undef unless $err;

  my ($default, $cb);
  my $is_obj = blessed $err;
CHECK: for (my $i = 0; $i < @spec; $i += 2) {
    my ($checks, $handler) = @spec[$i, $i + 1];

    ($default = $handler) and next if $checks eq 'default';

    for my $c (ref $checks eq 'ARRAY' ? @$checks : $checks) {
      my $is_re = ref $c eq 'Regexp';
      ($cb = $handler) and last CHECK if $is_obj  && !$is_re && $err->isa($c);
      ($cb = $handler) and last CHECK if !$is_obj && $is_re  && $err =~ $c;
    }
  }

  # Rethrow if no handler could be found
  die $err unless $cb ||= $default;
  $cb->($_) for $err;

  return 1;
}

sub inspect {
  my ($self, @sources) = @_;

  return $self if @{$self->line};

  # Extract file and line from message
  my @files;
  my $msg = $self->message;
  unshift @files, [$1, $2] while $msg =~ /at\s+(.+?)\s+line\s+(\d+)/g;

  # Extract file and line from stack trace
  if (my $zero = $self->frames->[0]) { push @files, [$zero->[1], $zero->[2]] }

  # Search for context in files
  for my $file (@files) {
    next unless -r $file->[0] && open my $handle, '<', $file->[0];
    $self->_context($file->[1], [[<$handle>]]);
    return $self;
  }

  # Search for context in sources
  $self->_context($files[-1][1], [map { [split "\n"] } @sources]) if @sources;

  return $self;
}

sub new {
  defined $_[1] ? shift->SUPER::new(message => shift) : shift->SUPER::new;
}

sub to_string {
  my $self = shift;

  my $str = $self->message;
  return $str unless $self->verbose;

  $str .= "\n" unless $str =~ /\n$/;
  $str .= $_->[0] . ': ' . $_->[1] . "\n" for @{$self->lines_before};
  $str .= $self->line->[0] . ': ' . $self->line->[1] . "\n" if $self->line->[0];
  $str .= $_->[0] . ': ' . $_->[1] . "\n" for @{$self->lines_after};
  $str .= "$_->[1]:$_->[2] ($_->[0])\n"   for @{$self->frames};

  return $str;
}

sub throw { CORE::die shift->new(shift)->trace(2) }

sub trace {
  my ($self, $start) = (shift, shift // 1);
  my @frames;
  while (my @trace = caller($start++)) { push @frames, \@trace }
  return $self->frames(\@frames);
}

sub _append {
  my ($stack, $line) = @_;
  $line = decode('UTF-8', $line) // $line;
  chomp $line;
  push @$stack, $line;
}

sub _context {
  my ($self, $num, $sources) = @_;

  # Line
  return unless defined $sources->[0][$num - 1];
  $self->line([$num]);
  _append($self->line, $_->[$num - 1]) for @$sources;

  # Before
  for my $i (2 .. 6) {
    last if ((my $previous = $num - $i) < 0);
    unshift @{$self->lines_before}, [$previous + 1];
    _append($self->lines_before->[0], $_->[$previous]) for @$sources;
  }

  # After
  for my $i (0 .. 4) {
    next if ((my $next = $num + $i) < 0);
    next unless defined $sources->[0][$next];
    push @{$self->lines_after}, [$next + 1];
    _append($self->lines_after->[-1], $_->[$next]) for @$sources;
  }
}

package Mojo::Exception::_Guard;
use Mojo::Base -base;

sub DESTROY { shift->{finally}->() }

1;

=encoding utf8

=head1 NAME

Mojo::Exception - Exception base class

=head1 SYNOPSIS

  # Create exception classes
  package MyApp::X::Foo {
    use Mojo::Base 'Mojo::Exception';
  }
  package MyApp::X::Bar {
    use Mojo::Base 'Mojo::Exception';
  }

  # Throw exceptions and handle them gracefully
  use Mojo::Exception 'check';
  eval {
    MyApp::X::Foo->throw('Something went wrong!');
  };
  check
    'MyApp::X::Foo' => sub { say "Foo: $_" },
    'MyApp::X::Bar' => sub { say "Bar: $_" };

=head1 DESCRIPTION

L<Mojo::Exception> is a container for exceptions with context information.

=head1 FUNCTIONS

L<Mojo::Exception> implements the following functions, which can be imported
individually.

=head2 check

  my $bool = check 'MyApp::X::Foo' => sub {...};
  my $bool = check $err, 'MyApp::X::Foo' => sub {...};

Process exceptions by dispatching them to handlers with one or more matching
conditions. Exceptions that could not be handled will be rethrown automatically.
By default C<$@> will be used as exception source, so C<check> needs to be
called right after C<eval>. Note that this function is EXPERIMENTAL and might
change without warning!

  # Handle various types of exceptions
  eval {
    dangerous_code();
  };
  check(
    'MyApp::X::Foo' => sub {
      warn "Foo: $_";
    },
    'MyApp::X::Bar' => sub {
      warn "Bar: $_";
    },
    qr/Could not open/ => sub {
      warn "Open error: $_";
    },
    default => sub {
      warn "Something went wrong: $_";
    },
    finally => sub {
      say 'Dangerous code is done';
    }
  );

Matching conditions can be class names for ISA checks on exception objects, or
regular expressions to match string exceptions. The matching exception will be
the first argument passed to the callback, and is also available as C<$_>.

  # Catch MyApp::X::Foo object or a specific string exception
  eval {
    dangerous_code();
  };
  check
    'MyApp::X::Foo'     => sub { warn "Foo: $_" },
    qr/^Could not open/ => sub { warn "Open error: $_" };

An array reference can be used to share the same handler with multiple
conditions, of which only one needs to match.

  # Handle MyApp::X::Foo and MyApp::X::Bar the same
  eval {
    dangerous_code();
  };
  check
    ['MyApp::X::Foo', 'MyApp::X::Bar'] => sub { warn "Foo/Bar: $_" },
    'MyApp::X::Yada'                   => sub { warn "Yada: $_" };

There are currently two keywords you can use to set special handlers. The
C<default> handler is used when no other handler matched. And the C<finally>
handler runs always, it does not affect normal handlers and even runs if the
exception was rethrown or if there was no exception to be handled at all.

  # Use the "default" fallback if nothing else matched
  eval {
    dangerous_code();
  };
  check
    'MyApp::X::Bar' => sub { warn "Bar: $_" },
    default         => sub { warn "Error: $_" },
    finally         => sub { say 'Dangerous code is done' };

=head1 ATTRIBUTES

L<Mojo::Exception> implements the following attributes.

=head2 frames

  my $frames = $e->frames;
  $e         = $e->frames([$frame1, $frame2]);

Stack trace if available.

  # Extract information from the last frame
  my ($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext,
      $is_require, $hints, $bitmask, $hinthash) = @{$e->frames->[-1]};

=head2 line

  my $line = $e->line;
  $e       = $e->line([3, 'die;']);

The line where the exception occurred if available.

=head2 lines_after

  my $lines = $e->lines_after;
  $e        = $e->lines_after([[4, 'say $foo;'], [5, 'say $bar;']]);

Lines after the line where the exception occurred if available.

=head2 lines_before

  my $lines = $e->lines_before;
  $e        = $e->lines_before([[1, 'my $foo = 23;'], [2, 'my $bar = 24;']]);

Lines before the line where the exception occurred if available.

=head2 message

  my $msg = $e->message;
  $e      = $e->message('Died at test.pl line 3.');

Exception message, defaults to C<Exception!>.

=head2 verbose

  my $bool = $e->verbose;
  $e       = $e->verbose($bool);

Enable context information for L</"to_string">.

=head1 METHODS

L<Mojo::Exception> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 inspect

  $e = $e->inspect;
  $e = $e->inspect($source1, $source2);

Inspect L</"message">, L</"frames"> and optional additional sources to fill
L</"lines_before">, L</"line"> and L</"lines_after"> with context information.

=head2 new

  my $e = Mojo::Exception->new;
  my $e = Mojo::Exception->new('Died at test.pl line 3.');

Construct a new L<Mojo::Exception> object and assign L</"message"> if necessary.

=head2 to_string

  my $str = $e->to_string;

Render exception.

  # Render exception with context
  say $e->verbose(1)->to_string;

=head2 throw

  Mojo::Exception->throw('Something went wrong!');

Throw exception from the current execution context.

  # Longer version
  die Mojo::Exception->new('Something went wrong!')->trace;

=head2 trace

  $e = $e->trace;
  $e = $e->trace($skip);

Generate stack trace and store all L</"frames">, defaults to skipping C<1> call
frame.

  # Skip 3 call frames
  $e->trace(3);

  # Skip no call frames
  $e->trace(0);

=head1 OPERATORS

L<Mojo::Exception> overloads the following operators.

=head2 bool

  my $bool = !!$e;

Always true.

=head2 stringify

  my $str = "$e";

Alias for L</"to_string">.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
