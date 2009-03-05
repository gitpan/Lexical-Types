#!perl -T

use strict;
use warnings;

use Test::More tests => 4;

sub Int::TYPEDSCALAR { (caller(0))[2] }

{
 use Lexical::Types;

 my Int $a;
 is $a, __LINE__-1, 'single';

 my Int ($b, $c);
 is $b, __LINE__-1, 'double (a)';
 is $c, __LINE__-2, 'double (b)';

 for my Int $d (0) {
  is $d, 0, 'for';
 }
}
