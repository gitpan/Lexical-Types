#!perl

use strict;
use warnings;

use lib 't/lib';
use VPIT::TestHelpers;
use Lexical::Types::TestThreads;

use Test::More tests => 2;

{
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

{
 my $status = run_perl <<' RUN';
  use threads;
  BEGIN { require Lexical::Types; }
  sub X::DESTROY {
   eval 'use Lexical::Types; package Z; my Z $z = 1';
   exit 1 if $@;
  }
  threads->create(sub {
   my $x = bless { }, 'X';
   $x->{self} = $x;
   return;
  })->join;
  exit 0;
 RUN
 is $status, 0, 'Lexical::Types can be loaded in eval STRING during global destruction at the end of a thread';
}
