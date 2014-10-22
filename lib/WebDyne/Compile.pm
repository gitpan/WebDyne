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
#
package WebDyne::Compile;


#  Packace init, attempt to load optional Time::HiRes module
#
sub BEGIN	{ 
    local $SIG{__DIE__}; 
    $^W=0; 
    eval("use Time::HiRes qw(time)") || eval { undef };
}


#  Pragma
#
use strict	qw(vars);
use vars	qw($VERSION %CGI_TAG_WEBDYNE %CGI_TAG_IMPLICIT);
use warnings;
no  warnings	qw(uninitialized redefine once);


#  External Modules
#
use WebDyne;
use WebDyne::HTML::TreeBuilder;
use Storable;
use IO::File;
use CGI qw(-no_xhtml);
use CGI::Util;


#  WebDyne Modules
#
use WebDyne::Constant;
use WebDyne::Base;


#  Version information
#
$VERSION='1.018';


#  Debug load
#
debug("Loading %s version $VERSION", __PACKAGE__);


#  Tags that are case sensitive
#
our %CGI_Tag_Ucase=map { $_=>ucfirst($_) } (

    qw(select tr link delete accept sub)

   );


#  Get WebDyne and CGI tags from TreeBuilder module
#
*CGI_TAG_WEBDYNE =\%WebDyne::CGI_TAG_WEBDYNE;
*CGI_TAG_IMPLICIT=\%WebDyne::HTML::TreeBuilder::CGI_TAG_IMPLICIT;


#  Need the start/end_html code ref for later on
#
my $CGI_start_html_cr=UNIVERSAL::can(CGI,'start_html');
my $CGI_end_html_cr=UNIVERSAL::can(CGI,'end_html');


#  Var to hold package wide hash, for data shared across package
#
my %Package;


#  All done. Positive return
#
1;


#==================================================================================================


sub new {


    #  Only used when debugging from outside apache, eg test script. If so, user
    #  must create new object ref, then run the compile. See wdcompile script for
    #  example. wdcompile is only used for debugging - we do some q&d stuff here
    #  to make it work
    #
    my $class=shift();


    #  Init WebDyne module
    #
    WebDyne->init_class();
    require WebDyne::Request::Fake;
    my $r=WebDyne::Request::Fake->new();


    #  New self ref
    #
    my %self=(

	_r	=>	$r,
	_CGI	=>	CGI->new(),
	_time	=>	time()

       );


    #  And return blessed ref
    #
    return bless \%self, 'WebDyne';


}


sub compile {


    #  Compile HTML file into Storable structure
    #
    my ($self, $param_hr)=@_;


    #  Start timer so we can log how long it takes us to compile a file
    #
    my $time=time();


    #  Init class if not yet done
    #
    (ref($self))->{_compile_init} ||= do {
	$self->compile_init() || return err() };


    #  Debug
    #
    debug('compile %s', Dumper($param_hr));


    #  Get srce and dest
    #
    my ($html_cn, $dest_cn)=@{$param_hr}{qw(srce dest)};


    #  Need request object ref
    #
    my $r=$self->{'_r'} || $self->r() || return err();


    #  Get CGI ref
    #
    my $cgi_or=$self->{'_CGI'} || $self->CGI() || return err();


    #  Turn off xhtml in CGI - should work in pragma, seems dodgy - seems like
    #  we must do every time we compile a page
    #
    $CGI::XHTML=0;


    #  Nostick
    #
    $CGI::NOSTICKY=1;


    #  Open the file
    #
    my $html_fh=IO::File->new($html_cn, O_RDONLY) ||
	return err("unable to open file $html_cn, $!");


    #  Get new TreeBuilder object
    #
    my $html_ox=WebDyne::HTML::TreeBuilder->new(

	api_version =>	3,

       ) || return err('unable to create HTML::TreeBuilder object');


    #  Tell HTML::TreeBuilder we do *not* want to ignore tags it
    #  considers "unknown". Since we use <PERL> and <BLOCK> tags,
    #  amongst other things, we need these to be in the tree
    #
    $html_ox->ignore_unknown(0);


    #  Tell it if we also want to see comments, use XML mode
    #
    $html_ox->store_comments($WEBDYNE_STORE_COMMENTS);
    $html_ox->xml_mode(1);


    #  No space compacting ?
    #
    $html_ox->ignore_ignorable_whitespace($WEBDYNE_COMPILE_IGNORE_WHITESPACE);
    $html_ox->no_space_compacting($WEBDYNE_COMPILE_NO_SPACE_COMPACTING);


    #  Get code ref closure of file to be parsed
    #
    my $parse_cr=$html_ox->parse_fh($html_fh) ||
	return err();


    #  Muck around with strictness of P tags
    #
    #$html_ox->implicit_tags(0);
    $html_ox->p_strict(1);


    #  Now parse through the file, running eof at end as per HTML::TreeBuilder
    #  man page.
    #
    $html_ox->parse($parse_cr);
    $html_ox->eof();


    #  And close the file handle
    #
    $html_fh->close();


    #  Now start iterating through the treebuilder object, creating
    #  our own array tree structure. Do this in a separate method that
    #  is rentrant as the tree is descended
    #
    my %meta=(
    
        manifest => [ \$html_cn ]
        
    );
    my $data_ar=$self->parse($html_ox, \%meta) || do {
	$html_ox->delete;
	undef $html_ox;
	return err();
    };
    debug("meta after parse %s", Dumper(\%meta));


    #  Now destroy the HTML::Treebuilder object, or else mem leak occurs
    #
    $html_ox=$html_ox->delete;
    undef $html_ox;


    #  Meta block
    #
    my $head_ar=$self->find_node({

 	data_ar	    =>  $data_ar,
 	tag	    =>	'head',

    }) || return err();
    my $meta_ar=$self->find_node({

 	data_ar	    =>  $head_ar->[0],
 	tag	    =>	'meta',
 	all_fg	    =>	1,

    }) || return err();
    foreach my $tag_ar (@{$meta_ar}) {
 	my $attr_hr=$tag_ar->[$WEBDYNE_NODE_ATTR_IX] || next;
 	if ($attr_hr->{'name'} eq 'WebDyne') {
 	    my @meta=split(/;/, $attr_hr->{'content'});
 	    debug('meta %s', Dumper(\@meta));
 	    foreach my $meta (@meta) {
		my ($name,$value)=split(/[=:]/, $meta, 2);
		defined($value) || ($value=1);

		#  Eval any meta attrs like @{}, %{}..
		my $hr=$self->subst_attr(undef, { $name=>$value }) ||
		    return err();
		$meta{$name}=$hr->{$name};
 	    }
	    #  Do not want anymore
 	    $self->delete_node({

		data_ar	=>	$data_ar,
		node_ar	=>	$tag_ar

	       }) || return err();
 	}
    }

    #  Construct final webdyne container
    #
    my @container=(keys %meta ? \%meta : undef, $data_ar);


    #  Quit if user wants to see tree at this stage
    #
    $param_hr->{'stage0'} && (return \@container);


    #  Store meta information for this instance so that when perl_init (or code running under perl_init)
    #  runs it can access meta data via $self->meta();
    #
    $self->{'_meta_hr'}=\%meta if keys %meta;
    if ((my $perl_ar=$meta{'perl'}) && !$param_hr->{'noperl'}) {

	#  This is inline __PERL__ perl. Must be executed before filter so any filters added by the __PERL__
	#  block are seen
	#
	my $perl_debug_ar=$meta{'perl_debug'};
	$self->perl_init($perl_ar, $perl_debug_ar) || return err();


    }


    #  Quit if user wants to see tree at this stage
    #
    $param_hr->{'stage1'} && (return \@container);


    #  Filter ?
    #
    my @filter=@{$meta{'webdynefilter'}};
    unless (@filter) {
	my $filter=$self->{'_filter'} || $r->dir_config('WebDyneFilter');
	@filter=split(/\s+/, $filter) if $filter;
    }
    debug('filter %s', Dumper(\@filter));
    if ((@filter) && !$param_hr->{'nofilter'}) {
        local $SIG{'__DIE__'};
	foreach my $filter (@filter) {
	    $filter=~s/::filter$//;
	    eval("require $filter") ||
		return err("unable to load filter $filter, ".lcfirst($@));
	    UNIVERSAL::can($filter, 'filter') ||
		return err("custom filter '$filter' does not seem to have a 'filter' method to call");
	    $filter.='::filter';
	    $data_ar=$self->$filter($data_ar, \%meta) || return err();
	}
    }


    #  Optimise tree, first step
    #
    $data_ar=$self->optimise_one($data_ar) || return err();


    #  Quit if user wants to see tree at this stage
    #
    $param_hr->{'stage2'} && (return \@container);


    #  Optimise tree, second step
    #
    $data_ar=$self->optimise_two($data_ar) ||
	return err();


    #  Quit if user wants to see tree at this stage
    #
    $param_hr->{'stage3'} && (return \@container);


    #  Is there any dynamic data ? If not, set meta html flag to indicate
    #  document is complete HTML
    #
    unless (grep { ref($_) } @{$data_ar}) {
	$meta{'html'}=1;
    }


    #  Construct final webdyne container
    #
    @container=(keys %meta ? \%meta : undef, $data_ar);


    #  Quit if user wants to final container
    #
    $param_hr->{'stage4'} && (return \@container);



    #  Save compiled object. Can't store code based cache refs, will be
    #  recreated anyway (when reloaded), so delete, save, then restore
    #
    my $cache_cr;
    if (ref($meta{'cache'}) eq 'CODE') { $cache_cr=delete $meta{'cache'} }


    #  Store to cache file if dest filename given
    #
    if ($dest_cn) {
	debug("attempting to cache to dest $dest_cn");
	local $SIG{'__DIE__'};
	eval { Storable::lock_store(\@container, $dest_cn) } || do {

	    #  This used to be fatal
	    #
	    #return err("error storing compiled $html_cn to dest $dest_cn, $@");


	    #  No more, just log warning and continue - no point crashing an otherwise
	    #  perfectly good app because we can't write to a directory
	    #
	    $r->log_error("error storing compiled $html_cn to dest $dest_cn, $@ - " .
			      'please ensure destination directory is writeable.')
		unless $Package{'warn_write'}++;
	    debug("caching FAILED to $dest_cn");

	};
    }
    else {
	debug('no destination file for compile - not caching');
    }


    #  Put the cache code ref back again now we have finished storing.
    #
    $cache_cr && ($meta{'cache'}=$cache_cr);


    #  Work out the page compile time, log
    #
    my $time_render=sprintf('%0.4f', time()-$time);
    debug("form $html_cn compile time $time_render");


    #  Destroy self
    #
    undef $self;


    #  Done
    #
    return \@container;

};


sub compile_init {


    #  Used to init package, move ugliness out of handler
    #
    my $class=shift();
    debug("in compile_init class $class");


    #  Init some CGI custom routines we need for correct compilation etc.
    #
    *{'CGI::~comment'}=sub {sprintf('<!--%s-->', $_[1]->{'text'})};
    $CGI::XHTML=0;
    $CGI::NOSTICKY=1;
    *CGI::start_html_cgi=$CGI_start_html_cr;
    *CGI::end_html_cgi=$CGI_end_html_cr;
    *CGI::start_html=sub {
	my ($self, $attr_hr)=@_;
	#CORE::print Data::Dumper::Dumper($attr_hr);
	keys %{$attr_hr} || ($attr_hr=$WEBDYNE_HTML_PARAM);
	my $html_attr=join(' ', map { qq($_="$attr_hr->{$_}") } keys %{$attr_hr});
	return $WEBDYNE_DTD.($html_attr ? "<html $html_attr>" : '<html>');
    };
    *CGI::end_html=sub {
 	'</html>'
    };
    *CGI::html=sub {
	my ($self, $attr_hr, @html)=@_;
	return join(undef, CGI->start_html($attr_hr), @html, $self->end_html);
    };


    #  Get rid of the simple escape routine, which mangles attribute characters we
    #  want to keep
    #
    *CGI::Util::simple_escape=sub { shift() };


    #  Get rid of compiler warnings on start and end routines
    #
    #0 && *CGI::start_html;
    #0 && *CGI::end_html;


    #  All done
    #
    return \undef;


}


sub optimise_one {


    #  Optimise a data tree
    #
    my ($self, $data_ar)=@_;


    #  Debug
    #
    debug('optimise stage one');


    #  Get CGI object
    #
    my $cgi_or=$self->{'_CGI'} ||
	return err("unable to get CGI object from self ref");


    #  Recursive anon sub to do the render
    #
    my $compile_cr=sub {


	#  Get self ref, node array
	#
	my ($compile_cr, $data_ar)=@_;


	#  Only do if we have children, if we do a foreach over nonexistent child node
	#  it will spring into existance as empty array ref, which we then have to
	#  wastefully store
	#
	if ($data_ar->[$WEBDYNE_NODE_CHLD_IX]) {


	    #  Process sub nodes to get child html data
	    #
	    foreach my $data_chld_ix (0 .. $#{$data_ar->[$WEBDYNE_NODE_CHLD_IX]}) {


		#  Get data child
		#
		my $data_chld_ar=$data_ar->[$WEBDYNE_NODE_CHLD_IX][$data_chld_ix];
		debug("data_chld_ar $data_chld_ar");


		#  If ref, recursivly run through compile process
		#
		ref($data_chld_ar) && do {


		    #  Run through compile sub-process
		    #
		    my $data_chld_xv=$compile_cr->($compile_cr, $data_chld_ar) ||
			return err();
		    if (ref($data_chld_xv) eq 'SCALAR') {
			$data_chld_xv=${$data_chld_xv}
		    }


		    #  Replace in tree
		    #
		    $data_ar->[$WEBDYNE_NODE_CHLD_IX][$data_chld_ix]=$data_chld_xv;

		}

	    }

	};


	#  Get this node tag and attrs
	#
	my ($html_tag, $attr_hr)=
	    @{$data_ar}[$WEBDYNE_NODE_NAME_IX, $WEBDYNE_NODE_ATTR_IX];
	debug("tag $html_tag, attr %s", Dumper($attr_hr));

	#  Store data block as hint to error handler should something go wrong
	#
	$self->{'_data_ar'}=$data_ar;


	#  Check to see if any of the attributes will require a subst to be carried out
	#
	my @subst_oper;
	#my $subst_fg=grep { $_=~/([$|@|%|!|+|^|*]{1})\{([$|@|%|!|+|^|*]?)(.*?)\2\}/s && push (@subst_oper, $1) } values %{$attr_hr};
	my $subst_fg=grep { $_=~/([\$@%!+*^]){1}{(\1?)(.*?)\2}/ && push (@subst_oper, $1) } values %{$attr_hr};


	#  Do not subst comments
	#
	($html_tag=~/~comment$/) && ($subst_fg=undef);


	#  If subst_fg present, means we must do a subst on attr vars. Flag
	#
	$subst_fg && ($data_ar->[$WEBDYNE_NODE_SBST_IX]=1);


	#  A CGI tag can be marked static, means that we can pre-render it for efficieny
	#
	my $static_fg=$attr_hr->{'static'};
	debug("tag $html_tag, static_fg $static_fg, subst_fg $subst_fg, subst_oper %s", Dumper(\@subst_oper));


	#  If static, but subst requires an eval, we can do now *only* if @ or % tags though,
	#  and some !'s that do not need request object etc. Cannot do on $
	#
	if ($static_fg && $subst_fg) {


	    #  Cannot optimes subst values with ${value}, must do later
	    #
	    (grep { $_ eq '$' } @subst_oper) && return $data_ar;


	    #  Do it
	    #
	    $attr_hr=$self->WebDyne::subst_attr(undef, $attr_hr) ||
		return err();

	}


	#  If not special WebDyne tag, see if we can render node
	#
	#if ((!$CGI_TAG_WEBDYNE{$html_tag} && !$CGI_TAG_IMPLICIT{$html_tag} && !$subst_fg) || $static_fg) {
	if ((!$CGI_TAG_WEBDYNE{$html_tag} && !$subst_fg) || $static_fg) {


	    #  Check all child nodes to see if ref or scalar
	    #
	    my $ref_fv=$data_ar->[$WEBDYNE_NODE_CHLD_IX] &&
		grep { ref($_) } @{$data_ar->[$WEBDYNE_NODE_CHLD_IX]};


	    #  If all scalars (ie no refs found)t, we can simply pre render all child nodes
	    #
	    unless ($ref_fv) {


		#  Done with static tag, delete so not rendered
		#
		delete $attr_hr->{'static'};


		#  Special case. If WebDyne tag and static, render now via WebDyne. Experimental
		#
		if ($CGI_TAG_WEBDYNE{$html_tag}) {


		    #  Render via WebDyne
		    #
		    debug("about to render tag $html_tag, attr %s", Dumper($attr_hr));
		    my $html_sr=$self->$html_tag($data_ar, $attr_hr) ||
			return err();
		    debug("html *$html_sr*, *${$html_sr}*");
		    return $html_sr;


		}


		#  Wrap up in our HTML tag. Do in eval so we can catch errors from invalid tags etc
		#
		my @data_child_ar=$data_ar->[$WEBDYNE_NODE_CHLD_IX] ? @{$data_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;
		my $html=eval {
		    $cgi_or->$html_tag(grep {$_} $attr_hr, join(undef, @data_child_ar))} ||
			#  Use errsubst as CGI may have DIEd during eval and be caught by WebDyne SIG handler
			return errsubst(
			    "CGI tag '<$html_tag>': %s",
			    $@ || "undefined error rendering tag '$html_tag'"
			);


		#  Debug
		#
		#debug("html *$html*");


		#  Done
		#
		return \$html;

	    }

	}


	#  Return current node, perhaps now somewhat optimised
	#
	$data_ar

    };


    #  Run it
    #
    $data_ar=$compile_cr->($compile_cr, $data_ar) || return err();


    #  If scalar ref returned it is all HTML - return as plain scalar
    #
    if (ref($data_ar) eq 'SCALAR') {
	$data_ar=${$data_ar}
    }


    #  Done
    #
    $data_ar;

}



sub optimise_two {


    #  Optimise a data tree
    #
    my ($self, $data_ar)=@_;


    #  Debug
    #
    debug('optimise stage two');


    #  Get CGI object
    #
    my $cgi_or=$self->{'_CGI'} ||
	return err("unable to get CGI object from self ref");


    #  Recursive anon sub to do the render
    #
    my $compile_cr=sub {


	#  Get self ref, node array
	#
	my ($compile_cr, $data_ar, $data_uppr_ar)=@_;


	#  Only do if we have children, if do a foreach over nonexistent child node
	#  it will spring into existance as empty array ref, which we then have to
	#  wastefully store
	#
	if ($data_ar->[$WEBDYNE_NODE_CHLD_IX]) {



	    #  Process sub nodes to get child html data
	    #
	    my @data_child_ar=$data_ar->[$WEBDYNE_NODE_CHLD_IX] ?
		@{$data_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;
	    foreach my $data_chld_ar (@data_child_ar) {


		#  Debug
		#
		#debug("found child node $data_chld_ar");


		#  If ref, run through compile process recursively
		#
		ref($data_chld_ar) && do {


		    #  Run through compile sub-process
		    #
		    $data_ar=$compile_cr->($compile_cr, $data_chld_ar, $data_ar) ||
			return err();

		}


	    }

	}


	#  Get this tag and attrs
	#
	my ($html_tag, $attr_hr)=
	    @{$data_ar}[$WEBDYNE_NODE_NAME_IX, $WEBDYNE_NODE_ATTR_IX];
	debug("tag $html_tag");
	
	
	#  Store data block as hint to error handler should something go wrong
	#
	$self->{'_data_ar'}=$data_ar;


	#  Check if this tag attributes will need substitution (eg ${foo});
	#
	#my $subst_fg=grep { $_=~/([$|@|%|!|+|^|*]{1})\{([$|@|%|!|+|^|*]?)(.*?)\2\}/s } values %{$attr_hr};
	my $subst_fg=grep { $_=~/([\$@%!+*^]){1}{(\1?)(.*?)\2}/so } values %{$attr_hr};


	#  If subst_fg present, means we must do a subst on attr vars. Flag, also get static flag
	#
	$subst_fg && ($data_ar->[$WEBDYNE_NODE_SBST_IX]=1);
	my $static_fg=delete $attr_hr->{'static'};


	#  If not special WebDyne tag, and no dynamic params we can render this node into
	#  its final HTML format
	#
	if (!$CGI_TAG_WEBDYNE{$html_tag} && !$CGI_TAG_IMPLICIT{$html_tag} && $data_uppr_ar && !$subst_fg) {


	    #  Get nodes into array now, removes risk of iterating over shifting ground
	    #
	    my @data_child_ar=$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX] ?
		@{$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;


	    #  Get uppr node
	    #
	    foreach my $data_chld_ix (0 .. $#data_child_ar) {


		#  Get node, skip unless ref
		#
		my $data_chld_ar=$data_child_ar[$data_chld_ix];
		ref($data_chld_ar) || next;


		#  Debug
		#
		#debug("looking at node $data_chld_ix, $data_chld_ar vs $data_ar");


		#  Skip unless eq us
		#
		next unless ($data_chld_ar eq $data_ar);


		#  Get start and end tag methods
		#
		my ($html_tag_start, $html_tag_end)=
		    ("start_${html_tag}", "end_${html_tag}");


		#  Translate tags into HTML
		#
		my ($html_start, $html_end)=map {
		    eval { $cgi_or->$_(grep {$_} $attr_hr) } ||
			#  Use errsubst as CGI may have DIEd during eval and be caught by WebDyne SIG handler
			return errsubst(
			    "CGI tag '<$_>' error- %s",
			    $@ || "undefined error rendering tag '$_'"
			   );
		} ( $html_tag_start, $html_tag_end);



		#  Splice start and end tags for this HTML into appropriate place
		#
		splice @{$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]},$data_chld_ix,1,
		    $html_start,
			@{$data_ar->[$WEBDYNE_NODE_CHLD_IX]},
			    $html_end;

		#  Done, no need to iterate any more
		#
		last;


	    }



	    #  Concatenate all non ref values in the parent. Var to hold results
	    #
	    my @data_uppr;


	    #  Repopulate data child array, as probably changed in above foreach
	    #  block.
	    #
	    @data_child_ar=$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX] ?
		@{$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;
	    #@data_child_ar=@{$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]};


	    #  Begin concatenation
	    #
	    foreach my $data_chld_ix (0 .. $#data_child_ar) {


		#  Get child
		#
		my $data_chld_ar=$data_child_ar[$data_chld_ix];


		#  Can we concatenate with above node
		#
		if (@data_uppr && !ref($data_chld_ar) && !ref($data_uppr[$#data_uppr])) {


		    # Yes, concatentate
		    #
		    $data_uppr[$#data_uppr].=$data_chld_ar;

		}
		else {

		    #  No, push onto new data_uppr array
		    #
		    push @data_uppr, $data_chld_ar;

		}
	    }


	    #  Replace with new optimised array
	    #
	    $data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]=\@data_uppr;


	}
	elsif ($CGI_TAG_WEBDYNE{$html_tag} && $data_uppr_ar && $static_fg) {


	    #  Now render to make HTML and modify the data arrat above us with the rendered code
	    #
	    my $html_sr=$self->render({
		data	=> [$data_ar],
	    }) || return err();
	    my @data_child_ar=$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX] ?
		@{$data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;
	    foreach my $ix (0 .. $#data_child_ar) {
		if ($data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX][$ix] eq $data_ar) {
		    $data_uppr_ar->[$WEBDYNE_NODE_CHLD_IX][$ix] =${$html_sr};
		    last;
		}
	    }


	}
	elsif (!$data_uppr_ar) {


	    #  Must be at top node, as nothing above us,
	    #  get start and end tag methods
	    #
	    my ($html_tag_start, $html_tag_end)=
		("start_${html_tag}", "end_${html_tag}");


	    #  Get resulting start and ending HTML
	    #
	    my ($html_start, $html_end)=map {
		eval { $cgi_or->$_(grep {$_} $attr_hr) } ||
		    return errsubst(
			"CGI tag '<$_>': %s",
			$@ || "undefined error rendering tag '$_'"
		       );
		    #return err("$@" || "no html returned from tag $_")
	    } ($html_tag_start, $html_tag_end);
	    my @data_child_ar=$data_ar->[$WEBDYNE_NODE_CHLD_IX] ?
		@{$data_ar->[$WEBDYNE_NODE_CHLD_IX]} : undef;

	    #  Place start and end tags for this HTML into appropriate place
	    #
	    my @data=(
		$html_start,
		@data_child_ar,
		$html_end
	       );


	    #  Concatenate all non ref vals
	    #
	    my @data_new;
	    foreach my $data_chld_ix (0 .. $#data) {

		if ($data_chld_ix && !ref($data[$data_chld_ix]) && !(ref($data[$data_chld_ix-1]))) {
		    $data_new[$#data_new].=$data[$data_chld_ix];
		}
		else {
		    push @data_new,$data[$data_chld_ix]
		}

	    }


	    #  Return completed array
	    #
	    $data_uppr_ar=\@data_new;


	}


	#  Return current node
	#
	return $data_uppr_ar;


    };


    #  Run it, return whatever it does, allowing for the special case that first stage
    #  optimisation found no special tags, and precompiled the whole array into a
    #  single HTML string. In which case return as array ref to allow for correct storage
    #  and rendering.
    #
    return ref($data_ar) ?
	$compile_cr->($compile_cr, $data_ar, undef) || err() :
	    [$data_ar];



}


sub parse {


    #  A recusively called method to parse a HTML::Treebuilder tree. content is an
    #  array ref of the HTML entity contents, return custom array tree from that
    #  structure
    #
    my ($self, $html_or, $meta_hr)=@_;
    my ($line_no, $line_no_tag_end)=@{$html_or}{'_line_no', '_line_no_tag_end'};
    debug("parse $self, $html_or line_no $line_no line_no_tag_end $line_no_tag_end");
    #debug("parse $html_or, %s", Dumper($html_or));


    #  Create array to hold this data node
    #
    my @data;
    @data[
        $WEBDYNE_NODE_NAME_IX,
        $WEBDYNE_NODE_ATTR_IX,
        $WEBDYNE_NODE_CHLD_IX,
        $WEBDYNE_NODE_SBST_IX,
        $WEBDYNE_NODE_LINE_IX,
        $WEBDYNE_NODE_LINE_TAG_END_IX,
        $WEBDYNE_NODE_SRCE_IX
    ]=(
        undef, undef, undef, undef, $line_no, $line_no_tag_end, $meta_hr->{'manifest'}[0]
    );


    #  Get tag
    #
    my $html_tag=$html_or->tag();


    #  Check special cases like tr that need to be uppercased (Tr) to work correctly
    #  in CGI
    #
    $html_tag=$CGI_Tag_Ucase{$html_tag} || $html_tag;
    
    
    #  Check valid
    #
    unless (UNIVERSAL::can('CGI', $html_tag) || $CGI_TAG_WEBDYNE{$html_tag}) { 
        return err("unknown CGI/WebDyne tag: $html_tag")
    }


    #  Get tag attr
    #
    if (my %attr=map { $_=>$html_or->{$_} } (grep {!/^_/} keys %{$html_or})) {


	#  Save tagm attr into node
	#
	#@data[$WEBDYNE_NODE_NAME_IX, $WEBDYNE_NODE_ATTR_IX]=($html_tag, \%attr);


	#  Is this the inline perl __PERL__ block ?
	#
	if ($html_or->{'_code'} && $attr{'perl'}) {
	    push @{$meta_hr->{'perl'}}, \$attr{'perl'};
	    push @{$meta_hr->{'perl_debug'}}, [$line_no_tag_end, $meta_hr->{'manifest'}[0]];
        }
	else {
	    @data[$WEBDYNE_NODE_NAME_IX, $WEBDYNE_NODE_ATTR_IX]=($html_tag, \%attr);
        }

    }
    else {


	#  No attr, just save tag
	#
	$data[$WEBDYNE_NODE_NAME_IX]=$html_tag;

    }


    #  Child nodes
    #
    my @html_child=@{$html_or->content()};


    #  Get child, parse down the tree
    #
    foreach my $html_child_or (@html_child) {

	debug("html_child_or $html_child_or");


	#  Ref is a sub-tag, non ref is plain text
	#
	if (ref($html_child_or)) {


	    #  Sub tag. Recurse down tree, updating to nearest line number
	    #
            $line_no=$html_child_or->{'_line_no'};
            my $data_ar=$self->parse($html_child_or, $meta_hr) ||
		return err();


	    #  If no node name returned is not an error, just a no-op
	    #
            if ($data_ar->[$WEBDYNE_NODE_NAME_IX]) {
		push @{$data[$WEBDYNE_NODE_CHLD_IX]}, $data_ar;
            }

	}
	else {

	    #  Node is just plain text. Used to not insert empty children, but this
	    #  stuffed up <pre> sections that use \n for spacing/formatting. Now we
	    #  are more careful
	    #
	    push (@{$data[$WEBDYNE_NODE_CHLD_IX]}, $html_child_or) 
		unless  ($html_child_or=~/^\s*$/ &&
			     ($html_tag ne 'pre') && ($html_tag ne 'textarea') && !$WEBDYNE_COMPILE_NO_SPACE_COMPACTING);

	}

    }


    #  All done, return data node
    #
    return \@data;

}

