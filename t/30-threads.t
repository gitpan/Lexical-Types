#!perl -T

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
  plan tests => 10 * 2 * 3 * (1 + 2);
  defined and diag "Using threads $_" for $threads::VERSION;
 } else {
  plan skip_all => 'This Lexical::Types isn\'t thread safe';
 }
}

{
 package Lexical::Types::Test::Tag;

 sub TYPEDSCALAR {
  my $tid = threads->tid();
  my ($file, $line) = (caller(0))[1, 2];
  my $where = "at $file line $line in thread $tid";
  Test::More::is($_[0], __PACKAGE__, "base type is correct $where");
  Test::More::is($_[2], 'Tag', "original type is correct $where");
  $_[1] = $tid;
  ();
 }
}

{ package Tag; }

use Lexical::Types as => 'Lexical::Types::Test::';

sub try {
 my $tid = threads->tid();

 for (1 .. 2) {
  my Tag $t;
  is $t, $tid, "typed lexical correctly initialized at run $_ in thread $tid";

  eval <<'EVALD';
   use Lexical::Types as => "Lexical::Types::Test::";
   my Tag $t2;
   is $t2, $tid, "typed lexical correctly initialized in eval at run $_ in thread $tid";
EVALD
  diag $@ if $@;

SKIP:
  {
   skip 'Hints aren\'t propagated into eval STRING below perl 5.10' => 3
                                                             unless $] >= 5.010;
   eval <<'EVALD';
    my Tag $t3;
    is $t3, $tid, "typed lexical correctly initialized in eval (propagated) at run $_ in thread $tid"
EVALD
  }
 }
}

my @t = map threads->create(\&try), 1 .. 10;
$_->join for @t;
