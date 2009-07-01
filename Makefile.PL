use 5.008;

use strict;
use warnings;
use ExtUtils::MakeMaker;

my @DEFINES;

# Threads, Windows and 5.8.x don't seem to be best friends
if ($^O eq 'MSWin32' && $^V lt v5.9.0) {
 push @DEFINES, '-DLT_MULTIPLICITY=0';
}

@DEFINES = (DEFINE => join ' ', @DEFINES) if @DEFINES;

my $dist = 'Lexical-Types';

my %META = (
 configure_requires => {
  'ExtUtils::MakeMaker' => 0,
 },
 build_requires => {
  'ExtUtils::MakeMaker' => 0,
  'Test::More'          => 0,
  'constant'            => 0,
 },
 resources => {
  bugtracker => "http://rt.cpan.org/NoAuth/ReportBug.html?Queue=$dist",
  homepage   => "http://search.cpan.org/dist/$dist/",
  license    => 'http://dev.perl.org/licenses/',
  repository => "http://git.profvince.com/?p=perl%2Fmodules%2F$dist.git",
 },
);

WriteMakefile(
    NAME             => 'Lexical::Types',
    AUTHOR           => 'Vincent Pit <perl@profvince.com>',
    LICENSE          => 'perl',
    VERSION_FROM     => 'lib/Lexical/Types.pm',
    ABSTRACT_FROM    => 'lib/Lexical/Types.pm',
    PL_FILES         => {},
    @DEFINES,
    PREREQ_PM        => {
        'Carp'          => 0,
        'XSLoader'      => 0,
    },
    MIN_PERL_VERSION => 5.008,
    META_MERGE       => \%META,
    dist             => {
        PREOP    => 'pod2text lib/Lexical/Types.pm > $(DISTVNAME)/README',
        COMPRESS => 'gzip -9f', SUFFIX => 'gz'
    },
    clean            => {
        FILES => "$dist-* *.gcov *.gcda *.gcno cover_db Debian_CPANTS.txt"
    }
);
