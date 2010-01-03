#!perl

use strict;
use warnings;

use Config qw/%Config/;

BEGIN {
 if (!$Config{useithreads}) {
  require Test::More;
  Test::More->import;
  plan(skip_all => 'This perl wasn\'t built to support threads');
 }
}

use threads;

use Test::More;

BEGIN {
 require Lexical::Types;
 if (Lexical::Types::LT_THREADSAFE()) {
  plan tests => 1;
  defined and diag "Using threads $_" for $threads::VERSION;
 } else {
  plan skip_all => 'This Lexical::Types isn\'t thread safe';
 }
}

sub run_perl {
 my $code = shift;

 local %ENV;
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
   $code = @expected = qw/IntX/;
   eval q{use Lexical::Types as => \&cb; my IntX $x;}; die if $@;
   return $code;
  })->join;
  $code += @expected = qw/IntZ/;
  eval q{my IntY $y;}; die if $@;
  eval q{use Lexical::Types as => \&cb; my IntZ $z;}; die if $@;
  $code += 256 if $code < 0;
  exit $code;
 RUN
 is $status, 0, 'loading the pragma in a thread and using it outside doesn\'t segfault';
}
