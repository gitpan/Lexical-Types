#!perl -T

use strict;
use warnings;

use Test::More tests => (1 + 2) + (1 + 4);

sub Int::TYPEDSCALAR { join ':', (caller 0)[1, 2] }

our ($x, $y, $z, $t);

use lib 't/lib';

{
 eval 'use Lexical::Types; use Lexical::Types::TestRequired1';
 is $@, '', 'first require test didn\'t croak prematurely';
}

{
 eval 'use Lexical::Types; use Lexical::Types::TestRequired2';
 is $@, '', 'second require test didn\'t croak prematurely';
}
