#!perl

use strict;
use warnings;

sub skipall {
 my ($msg) = @_;
 require Test::More;
 Test::More::plan(skip_all => $msg);
}

use Config qw<%Config>;

BEGIN {
 my $force = $ENV{PERL_LEXICAL_TYPES_TEST_THREADS} ? 1 : !1;
 skipall 'This perl wasn\'t built to support threads'
                                                    unless $Config{useithreads};
 skipall 'perl 5.13.4 required to test thread safety'
                                                unless $force or $] >= 5.013004;
}

use threads;

use Test::More;

BEGIN {
 require Lexical::Types;
 skipall 'This Lexical::Types isn\'t thread safe'
                                         unless Lexical::Types::LT_THREADSAFE();
 plan tests => 1;
 defined and diag "Using threads $_" for $threads::VERSION;
}

sub run_perl {
 my $code = shift;

 my $SystemRoot   = $ENV{SystemRoot};
 local %ENV;
 $ENV{SystemRoot} = $SystemRoot if $^O eq 'MSWin32' and defined $SystemRoot;

 system { $^X } $^X, '-T', map("-I$_", @INC), '-e', $code;
}

SKIP:
{
 skip 'Fails on 5.8.2 and lower' => 1 if $] <= 5.008002;

 my $status = run_perl <<' RUN';
  { package IntX; package IntY; package IntZ; }
  my ($code, @expected);
  sub cb {
   my $e = shift(@expected) || q{DUMMY};
   --$code if $_[0] eq $e;
   ()
  }
  use threads;
  $code = threads->create(sub {
   $code = @expected = qw<IntX>;
   eval q{use Lexical::Types as => \&cb; my IntX $x;}; die if $@;
   return $code;
  })->join;
  $code += @expected = qw<IntZ>;
  eval q{my IntY $y;}; die if $@;
  eval q{use Lexical::Types as => \&cb; my IntZ $z;}; die if $@;
  $code += 256 if $code < 0;
  exit $code;
 RUN
 is $status, 0, 'loading the pragma in a thread and using it outside doesn\'t segfault';
}
