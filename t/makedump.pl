#!/bin/perl

#  Create dump files in test directory from PSP sources
#
use strict qw(vars);
use vars qw($VERSION);
#use File::Spec;
use FindBin qw($RealBin $Script);
#use Cwd qw(realpath);
#use lib $RealBin;
#use perl5lib;
require 'perl5lib.pl';

use WebDyne::Request::Fake;
use WebDyne;
use File::Temp qw(tempfile);
use File::Find qw(find);
use IO::File;
use HTML::TreeBuilder;

my @test_fn;
my $wanted_sr=sub { push (@test_fn, $File::Find::name) if /\.psp$/ };
find($wanted_sr, $RealBin);
foreach my $test_fn (sort {$a cmp $b } @test_fn) {


    #  Create WebDyne render of PSP file and capture to file
    #
    print "file $test_fn\n";
    
    
    #  Check for en-us attribute - needed to consitency across CGI vers
    #
    my $test_fh=IO::File->new($test_fn, O_RDONLY) || die;
    my $html_ln=<$test_fh>;
    $test_fh->close();
    unless ($html_ln=~/en-US/) { die("no html 'lang=en-US' attribute found in file '$test_fn'")}
    
    
    #  Render to temp file
    #
    my $r=WebDyne::Request::Fake->new( filename=>$test_fn );
    my ($temp_fh, $temp_fn)=tempfile();
    my $select_fh=select;
    select $temp_fh;
    WebDyne->handler($r);
    #ok(defined(WebDyne->handler($r)), 'webdyne handler');
    $r->DESTROY();
    $temp_fh->close();
    select $select_fh;


    #  Create TreeBuilder dump of rendered text in temp file
    #
    (my $dump_fn=$test_fn)=~s/\.psp$/\.dmp/;
    my $dump_fh=IO::File->new($dump_fn, O_WRONLY|O_CREAT|O_TRUNC) ||
      die("unable to create dump file $dump_fn, $!");
    my $html_fh=IO::File->new($temp_fn, O_RDONLY);
    my $tree_or=HTML::TreeBuilder->new();
    while (my $html=<$html_fh>) {
	#  Do this way to get rid of extraneous CR's older version of CGI insert, spaces
	#  after tags which also differ from ver to ver, confusing test
	$html=~s/\n+$//;
	$html=~s/>\s+/>/g;
	$tree_or->parse($html);
    }
    $tree_or->eof();
    $html_fh->close();
    #ok($tree_or, 'HTML::TreeBuilder object');
    $tree_or->dump($dump_fh);
    $tree_or->delete();
    #diag("tree_fn $tree_fn");
    $dump_fh->close();
    
}
