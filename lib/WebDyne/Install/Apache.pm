#
#
#  Copyright (C) 2006-2010 Andrew Speer <andrew@webdyne.org>.
#  All rights reserved.
#
#  This file is part of WebDyne.
#
#  WebDyne is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#
package WebDyne::Install::Apache;


#  Compiler Pragma
#
sub BEGIN	{ $^W=0 };
use strict	qw(vars);
use vars	qw($VERSION);
use warnings;
no  warnings	qw(uninitialized);


#  Webmod Modules
#
use WebDyne::Base;


#  External Modules
#
use File::Spec;
use Text::Template;
use IO::File;


#  Base installer
#
use WebDyne::Install qw(message);


#  Constants
#
use WebDyne::Constant;
use WebDyne::Install::Constant;
use WebDyne::Install::Apache::Constant;


#  Version information
#
$VERSION='1.012';


#  Debug
#
debug("%s loaded, version $VERSION", __PACKAGE__);


#  Uninstaller global
#
my $Uninstall_fg;


#  Init done.
#
1;


#------------------------------------------------------------------------------


#  Uninstall
#
sub uninstall {

    #  Set flag and call install routine
    #
    $Uninstall_fg++;
    shift()->install(@_);

}


#  Install the Apache conf params needed to run the system
#
sub install {


    #  Get class, other paths
    #
    my ($class, $prefix, $installbin)=@_;


    #  Run the base install/uninstall routine to create the cache dir
    #
    unless ($Uninstall_fg) {
	WebDyne::Install->install($prefix, $installbin) ||
	    return err();
    }
    else {
	WebDyne::Install->uninstall($prefix, $installbin) ||
	    return err();
    }


    #  Get package file name so we can look up inc for templates
    #
    (my $class_dn=$class.q(.pm))=~s/::/\//g;


    #  Load constants, get full path for class and constants from INC
    #
    $class_dn=$INC{$class_dn} ||
	return err("unable to find location for $class in \%INC");


    #  Get file name component, then cut file out to get directory,
    #  split and reverse class for later use;
    #
    my $class_fn=(File::Spec->splitpath($class_dn))[2];
    $class_dn=~s/\Q$class_fn\E$//;
    my @class=reverse split(/::/, $class);


    #  Get webdyne cache dn;
    #
    my $cache_dn=&WebDyne::Install::cache_dn($prefix);


    #  Get config/constant hash ref
    #
    my %constant=(

	%WebDyne::Constant::Constant,
	%WebDyne::Install::Constant::Constant,
	%WebDyne::Install::Apache::Constant::Constant,
	DIR_INSTALLBIN	    => $installbin,
	WEBDYNE_CACHE_DN    => $cache_dn,

       );
    my $config_hr=\%constant;
    debug('config_hr %s', Dumper($config_hr));


    #  Cannot do anything without Apache binary
    #
    return err("unable to find apache binary")
      unless $config_hr->{'HTTPD_BIN'};


    #  Get template path name from module install dir.
    #
    my $template_dn=File::Spec->catdir($class_dn, $class[0]);
    my $template_fn=File::Spec->catfile(
	$template_dn, $config_hr->{'FILE_WEBDYNE_CONF_TEMPLATE'});


    #  Open it as a template
    #
    my $template_or=Text::Template->new(

        type    =>  'FILE',
        source  =>  $template_fn,

       ) || return err("unable to open template $template_fn, $!");


    #  Fill in with out self ref as a hash
    #
    my $webdyne_conf=$template_or->fill_in(

        HASH	    =>  $config_hr,
	DELIMITERS  =>  [ '<!--', '-->' ],

       ) || return err("unable to fill in template $template_fn, $Text::Template::ERROR");



    #  Get apache config dir
    #
    my $apache_conf_dn=$config_hr->{'DIR_APACHE_CONF'} ||
	return err('unable to determine Apache config directory');


    #  Work out config file name
    #
    my $webdyne_conf_fn=File::Spec->catfile(
	$apache_conf_dn, $config_hr->{'FILE_WEBDYNE_CONF'});


    #  Open, write webdyne config file unless in uninstall
    #
    unless ($Uninstall_fg) {
        message "writing Apache config file '$webdyne_conf_fn'.";
	my $webdyne_conf_fh=IO::File->new($webdyne_conf_fn, O_CREAT|O_WRONLY|O_TRUNC) ||
	    return err("unable to open file $webdyne_conf_fn, $!");
	print $webdyne_conf_fh $webdyne_conf;
	$webdyne_conf_fh->close();
    }
    else {

	#  In uninstall - get rid of conf file
	#
	if (-f $webdyne_conf_fn) {
	    unlink($webdyne_conf_fn) && message "remove config file $webdyne_conf_fn";
	}

    }


    #  Only modify config file if no conf.d dir, denoted by var below
    #
    unless ($config_hr->{'HTTPD_SERVER_CONFIG_SKIP'}) {


	#  Get Apache config file, append root if not absolute
	#
	my $apache_conf_fn=$config_hr->{'HTTPD_SERVER_CONFIG_FILE'} ||
	    return err("unable to determine main server config file");
	($apache_conf_fn=~/^\//) || (
	    $apache_conf_fn=File::Spec->catfile(
		$config_hr->{'HTTPD_ROOT'},$apache_conf_fn));
	my $apache_conf_fh=IO::File->new($apache_conf_fn, O_RDONLY) ||
	    return err("unable to open file $apache_conf_fn, $!");
	message "Apache config file '$apache_conf_fn'";


	#  Setup delims looking for
	#
	my ($delim, @delim)=$config_hr->{'FILE_APACHE_CONF_DELIM'};


	#  Turn into array, search for delims
	#
	my ($index, @apache_conf);
	while (my $line=<$apache_conf_fh>) {
	    push @apache_conf, $line;
	    push(@delim, $index) if $line=~/\Q$delim\E/;
	    $index++;
	}


	#  Check found right number of delims
	#
	if (@delim!=2 and @delim!=0) {

	    return err(
		"found %s '$delim' delimiter%s in $apache_conf_fn at line%s %s, expected exactly 2 delimiters",
		scalar @delim,
		($#delim ? 's' : '') x 2,
		join(',', @delim)
	       );

	}


	#  Check if delim found, if not, make last line
	#
	unless (@delim) { @delim=($index, $index-1) }
	$delim[1]++;


	#  Close
	#
	$apache_conf_fh->close();


	#  Splice the lines between the delimiters out
	#
	splice(@apache_conf, $delim[0], $delim[1]-$delim[0]);


	#  Clean up end of conf file, remove excess CR's
	#
	my $lineno=$delim[0]-1;
	for (undef; $lineno > 0; $lineno--) {


	    #  We are going backwards through the file, as soon as we
	    #  see something we quit
	    #
	    my $line=$apache_conf[$lineno];
	    chomp($line);


	    #  Empty
	    #
	    if ($line=~/^\s*$/) {


		#  Yes, delete and continue
		#
		splice(@apache_conf, $lineno, 1);

	    }
	    else {


		#  No, quit after rewinding lineno to last val
		#
		$lineno++;
		last;

	    }
	}


	#  Only splice back in if not uninstalling
	#
	unless ($Uninstall_fg) {


	    #  Get template we want to include in the config file
	    #
	    $template_fn=File::Spec->catfile(
		$template_dn, $config_hr->{'FILE_APACHE_CONF_TEMPLATE'});


	    #  Open it as a template
	    #
	    $template_or=Text::Template->new(

		type    =>  'FILE',
		source  =>  $template_fn,

	       ) || return err("unable to open template $template_fn, $!");


	    #  Fill in with out self ref as a hash
	    #
	    my $apache_conf=$template_or->fill_in(

		HASH	    => $config_hr,
		DELIMITERS  => [ '<!--', '-->' ],

	       ) || return err("unable to fill in template $template_fn, $Text::Template::ERROR");


	    #  Splice in now, but write out at end of block
	    #
	    splice(@apache_conf, $lineno, undef, $apache_conf);


	}


	#  Re-open httpd.conf for write out, unless uninstall and delims not found, which
	#  means nothing was changed.
	#
	unless ($Uninstall_fg && ($delim[0] == $delim[1])) {
	    $apache_conf_fh=IO::File->new($apache_conf_fn, O_TRUNC|O_WRONLY) ||
		return err("unable to open file $apache_conf_fn, $!");
	    print $apache_conf_fh join('', @apache_conf);
	    $apache_conf_fh->close();
	    message "Apache config file '$apache_conf_fn' updated.";
	}

    }
    else {

	#  No need to update Apache config file - using conf.d dir
	#
	message 'Apache uses conf.d directory - not changing httpd.conf file';

    }



    #  Almost done ..
    #
    unless ($Uninstall_fg) {

	#  Chown cache dir unless it is the system temp dir - then don't mess with it
	#
	if ($cache_dn) {
	    unless ($cache_dn eq File::Spec->tmpdir()) {
		message
		    "Granting Apache ($APACHE_UNAME.$APACHE_GNAME) ownership of cache directory '$cache_dn'.";
		chown($APACHE_UID, $APACHE_GID, $cache_dn) ||
		    return err("unable to chown $cache_dn to $APACHE_UNAME.$APACHE_GNAME");


		#  Selinx fixup
		#
		if ($SELINUX_ENABLED_BIN) {
		    if ((system($SELINUX_ENABLED_BIN)>>8)==0) {
			#  SELinux is enabled. chcon first
			#
			if (my $chcon_bin=$SELINUX_CHCON_BIN) {
			    message("Adding SELinux context '$SELINUX_CONTEXT' to cache directory '$cache_dn' via chcon");
			    if (my $rc=system($chcon_bin, '-R', '-t', $SELINUX_CONTEXT, $cache_dn)>>8) {
				message("WARNING: SELinux chcon of $cache_dn to $SELINUX_CONTEXT failed with error code $rc\n")
			    }
    			}
			else {
			    message('WARNING: SELinux appears enabled, but the \'chcon\' command was not found - '.
				    "your cache directory may not be writable\n");
			}

			#  Now semanage, if we can find it
			#
			if (my $semanage_bin=$SELINUX_SEMANAGE_BIN) {

			    #  List
			    #
			    my $selist=qx/$SELINUX_SEMANAGE_BIN fcontext -C -l -n/;
			    unless ($selist=~/^\Q$cache_dn\E/m) {

				#  Context not added yet
				#
				message("Adding SELinux context '$SELINUX_CONTEXT' to cache directory '$cache_dn' via semanage");
				if (my $rc=system($semanage_bin, 'fcontext', '-a', '-t', $SELINUX_CONTEXT, "${cache_dn}(/.*)?")>>8) {
				    message("WARNING: SELinux semanage of $cache_dn to $SELINUX_CONTEXT failed with error code $rc\n")
				}
			    }
			}
			else {
			    message('WARNING: SELinux semanage utility not found - chcon changes will be lost if SELinux relabel takes place.')
			}
		    }
		}


		# Done
		#
		message 'install completed.'

	    }
	}
    }
    else {

	message 'uninstall completed'

    };


    #  Finished
    message;
    return \undef;


}
