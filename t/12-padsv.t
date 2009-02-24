#!perl -T

use strict;
use warnings;

use File::Spec;

use Test::More tests => 3;

sub Str::TYPEDSCALAR {
 my $buf = (caller(0))[2];
 open $_[1], '<', \$buf;
 ()
}

use Lexical::Types;

my Str $x;
our $r = <$x>;
is $r, __LINE__-2, 'trick for our - readline';

my Str $y;
my $s = <$y>;
is $s, __LINE__-2, 'trick for my - readline';

my $z = 7;
is $z, 7, 'trick for others';
