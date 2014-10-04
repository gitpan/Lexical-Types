package Lexical::Types::TestThreads;

use strict;
use warnings;

use Config qw<%Config>;

use VPIT::TestHelpers;

sub import {
 shift;

 require Lexical::Types;

 skip_all 'This Lexical::Types isn\'t thread safe'
                                         unless Lexical::Types::LT_THREADSAFE();

 my $force = $ENV{PERL_LEXICAL_TYPES_TEST_THREADS} ? 1 : !1;
 skip_all 'This perl wasn\'t built to support threads'
                                                    unless $Config{useithreads};
 skip_all 'perl 5.13.4 required to test thread safety'
                                             unless $force or "$]" >= 5.013_004;

 load_or_skip_all('threads', $force ? '0' : '1.67', [ ]);

 my %exports = (
  spawn => \&spawn,
 );

 my $pkg = caller;
 while (my ($name, $code) = each %exports) {
  no strict 'refs';
  *{$pkg.'::'.$name} = $code;
 }
}

sub spawn {
 local $@;
 my @diag;
 my $thread = eval {
  local $SIG{__WARN__} = sub { push @diag, "Thread creation warning: @_" };
  threads->create(@_);
 };
 push @diag, "Thread creation error: $@" if $@;
 if (@diag) {
  require Test::Leaner;
  Test::Leaner::diag($_) for @diag;
 }
 return $thread ? $thread : ();
}

1;
