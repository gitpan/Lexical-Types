#!perl

use strict;
use warnings;

{
 package Str;

 sub TYPEDSCALAR { $_[1] = ' ' x 10 }
}

use Lexical::Types;

my Str $x;

print length($x), "\n"; # 10
