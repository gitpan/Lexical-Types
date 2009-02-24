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

use Test::More tests => 10 * 2;

{
 package Lexical::Types::Test::Tag;

 sub TYPEDSCALAR { $_[1] = threads->tid() }
}

{ package Tag; }

use Lexical::Types as => 'Lexical::Types::Test::';

sub try {
 for (1 .. 2) {
  my Tag $t;
  my $tid = threads->tid();
  is $t, $tid, "typed lexical correctly initialized at run $_ in thread $tid";
 }
}

my @t = map threads->create(\&try), 1 .. 10;
$_->join for @t;
