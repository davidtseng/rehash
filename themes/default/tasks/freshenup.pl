#!/usr/bin/perl -w
# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

use File::Path;
use File::Temp;
use Fcntl;
use Digest::MD5;
use Slash::Constants ':slashd';

use strict;
use utf8;
use open ':encoding(UTF-8)';
use open ':std';

use vars qw( %task $me $task_exit_flag
	$minutes_run
	$sectional_freq
);

# Change this var to change how often the task runs.  Sandboxes
# run it every ten minutes, Slashdot.org every minute.
$minutes_run = 1;

# Process the non-mainpage skins less often.  Sandboxes run them
# every 5 invocations, Slashdot.org every 10.
$sectional_freq = ($ENV{SF_SYSTEM_FUNC} =~ /^slashdot-/ ? 10 : 5);

$task{$me}{timespec} = freshenup_get_start_min($minutes_run) . "-59/$minutes_run * * * *";
$task{$me}{timespec_panic_1} = '1-59/10 * * * *';
$task{$me}{timespec_panic_2} = '';
$task{$me}{resource_locks} = getCurrentStatic('cepstral_audio') ? { cepstral => 1 } : { };
$task{$me}{on_startup} = 1;
$task{$me}{fork} = SLASHD_NOWAIT;
$task{$me}{code} = sub {
	my($virtual_user, $constants, $slashdb, $user, $info, $gSkin) = @_;
	my $start_time = time;
	my $basedir = $constants->{basedir};
	my $vu = "virtual_user=$virtual_user";
	my $args = "$vu ssi=yes";
	my %dirty_skins = ( );
	my $stories;


	# Every tenth invocation, we do a big chunk of work.  The other
	# nine times, we update the top three stories and the front
	# page, skipping all other nexuses and other stories -- and to
	# preserve the stories table's query cache, we only update
	# commentcount/hitparades if at least one of those three stories
	# had a small commentcount.
	my $do_all = ($info->{invocation_num} % $sectional_freq == 1) || 0;

	# If run with runtask, you can specify some options on the comand
	# line, e.g. to chew through writing .shtml files to disk for up
	# to five minutes:
	# runtask -u slashusername -o run_all=1,timeout_shtml=300 freshenup
	$do_all = 1 
		if $constants->{task_options}{run_all};
	my $timeout_render = $constants->{task_options}{timeout_render} || 30;
	my $timeout_shtml = $constants->{task_options}{timeout_shtml} || 90;

	my $max_stories = defined($constants->{freshenup_max_stories})
		? $constants->{freshenup_max_stories}
		: 100;
	$max_stories = 3 unless $do_all;

	my $stoids_to_refresh = [];
	if ($constants->{task_options}{stoid} || $constants->{task_options}{sid}) {
		my $sids_to_refresh = [];
		@$stoids_to_refresh = split (/ /, $constants->{task_options}{stoid}) if $constants->{task_options}{stoid};
		@$sids_to_refresh = split (/ /, $constants->{task_options}{sid}) if $constants->{task_options}{sid};
		foreach (@$sids_to_refresh) {
			my $stoid = $slashdb->getStoidFromSidOrStoid($_);
			push @$stoids_to_refresh, $stoid if $stoid;
		}
		foreach (@$stoids_to_refresh) {
			$slashdb->markStoryDirty($_);
		}
		$do_all = 1 if @$stoids_to_refresh;
	}

	############################################################
	# deletions
	############################################################

	if ($do_all) {
		my $x = 0;
		my $deletable = $slashdb->getStoriesToDelete($max_stories);
		for my $story (@$deletable) {
			$x++;
			$dirty_skins{$story->{primaryskid}} = 1;
			$slashdb->deleteStoryAll($story->{stoid});
			slashdLog("Deleting $story->{sid} ($story->{title})")
				if verbosity() >= 1;
		}
	}

	############################################################
	# users_count update (memcached and var)
	############################################################

	$slashdb->countUsers({ write_actual => 1 });

	############################################################
	# story_topics_rendered updates
	############################################################

	# Write new values into story_topics_rendered for any stories
	# which may have been affected by a topic tree change.  There
	# may be a large number of these (thousands?) and while we
	# can't do them all at once, we don't want to kill performance
	# by nuking the story_topics_rendered query cache every minute
	# while we do them piecemeal.  So instead, we try to take a
	# big bite out of what needs to be done while there are stories
	# within the latest 1000 that need this, and then afterwards,
	# take a smaller bite every 10 minutes at a do_all.  These
	# actually get processed pretty fast.
	$stories = $slashdb->getSRDsWithinLatest(1000);
	if (!@$stories) {
		if ($do_all) {
			# Try the smaller bite.
			$stories = $slashdb->getSRDs($max_stories);
		} else {
			# Either there's nothing to be done or there's
			# nothing urgent enough to be done.  Leave the
			# arrayref empty, do nothing now.
		}
	}
	# We're going to build up a hash that contains everything we
	# want to do, and apply it all at once, because if we're going
	# to nuke the query cache we might as well get it over with
	# quickly.
	if ($stories && @$stories) {
		my $update_hr = $slashdb->buildStoryRenderHashref($stories);
		$slashdb->applyStoryRenderHashref($update_hr)
			if !$task_exit_flag;
		$slashdb->markStoriesRenderClean($stories)
			if !$task_exit_flag;
	}

	############################################################
	# story_text.rendered updates
	############################################################

	# Render any stories that need rendering.  This used to be done
	# by admin.pl;  now admin.pl just sets story_text.rendered=NULL
	# and lets this task do it.

	my %story_set = ( );
	my $story_update_ar = $slashdb->getStoriesNeedingRender(
		$do_all ? 10 : 3
	);
	STORIES_RENDER: for my $story_hr (@$story_update_ar) {

		my $stoid = $story_hr->{stoid};
		my $last_update = $story_hr->{last_update};

		# Don't run forever...
		if (time > $start_time + $timeout_render) {
			slashdLog("Aborting stories at render, too much elapsed time");
			last STORIES_RENDER;
		}
		if ($task_exit_flag) {
			slashdLog("Aborting stories at render, got SIGUSR1");
			last STORIES_RENDER;
		}

		my $rendered;
		{
			# XXXSKIN - not sure what to do here yet ...
			local $user->{currentSection} = "index";
			local $user->{noicons} = "";
			local $user->{light} = "";

			# ugly hack, but for now, needed: without it, when an
			# editor edits in foo.sitename.com, saved stories get
			# rendered with that section
			Slash::Utility::Anchor::getSkinColors();

			$rendered = displayStory($stoid,
				'', { force_cache_freshen => 1 });
		}
		$story_set{$stoid}{last_update} = $last_update;
		$story_set{$stoid}{rendered} = $rendered;
		$story_set{$stoid}{writestatus} = 'dirty';

	}

	############################################################
	# get commentcount and hitparade for stories
	############################################################

	# Freshen the static versions of any stories that have changed.
	# This means writing the .shtml files.

	$stories = [ ];
	if (!$task_exit_flag) {
		my $mp_tid = $constants->{mainpage_nexus_tid};
		my $gstr_options = {};
		$gstr_options->{stoid} = $stoids_to_refresh if @$stoids_to_refresh;
		$stories = $slashdb->getStoriesToRefresh($max_stories,
			$do_all ? 0 : $mp_tid, $gstr_options);
	}

	my $bailed = 0;
	my $totalChangedStories = 0;
	my $do_log;
	my $logmsg;

	# If 100 or more stories are marked as dirty, there is a backlog
	# that we aren't able to get to in the 90-second chunks here.
	# So extend more time to complete that work.  Note that since we
	# cue off the number of stories returned, this will only be
	# triggered during a $do_all pass, since otherwise the number of
	# stories to process is capped at 3.
	my $extra_minutes = int( scalar(@$stories)/100 );
	if ($extra_minutes) {
		$extra_minutes = 5 if $extra_minutes > 5;
		$timeout_shtml += 60 * $extra_minutes;
		slashdLog("Will process for $extra_minutes extra minutes, "
			. scalar(@$stories) . " stories");
	}

	STORIES_FRESHEN: for my $story (@$stories) {

		$do_log = (verbosity() >= 2);
		$logmsg = "";

		# Don't run forever freshening stories.  Before we
		# stomp on too many other invocations of freshenup.pl,
		# quit and let the next invocation get some work done.
		# Since this task is run every minute, quitting after
		# 90 seconds of work should mean we only stomp on the
		# one invocation following.
		# (But if there are many backlogged dirty stories, we
		# may stomp on 2, 3, or more invocations -- oh well.)
		if (time > $start_time + $timeout_shtml) {
			slashdLog("Aborting stories at freshen, too much elapsed time");
			last STORIES_FRESHEN;
		}
		if ($task_exit_flag) {
			slashdLog("Aborting stories at freshen, got SIGUSR1");
			last STORIES_FRESHEN;
		}

		my($stoid, $sid, $title, $skid) =
			@{$story}{qw( stoid sid title primaryskid )};
		my $skinname = '';
		my $story_skin = $slashdb->getSkin($skid) if $skid;
		if (!$story_skin || !%$story_skin) {
			slashdLog("skipping, nonexistent primaryskid '$skid' for $sid: $title");
			next STORIES_FRESHEN;
		}
		$skinname = $story_skin->{name};

		my $mp_tid = $constants->{mainpage_nexus_tid};
		my $displaystatus = $slashdb->_displaystatus($story->{stoid});
		
		slashdLog("Updating $sid") if verbosity() >= 3;
		# XXXSKIN no -- we should dirty *all* skins that this story is on
		$dirty_skins{$skid} = 1;
		if ($displaystatus == 0) {
			# If this story goes on the mainpage, its being
			# dirty means the main page is dirty too,
			# regardless of which section the story is in.
			$dirty_skins{$constants->{mainpage_skid}} = 1;
		}
		$totalChangedStories++;

		# We need to pull some data from a file that article.pl will
		# write to.  But first it needs us to create the file and
		# tell it where it will be.
		my($cchp_file, $cchp_param) = _make_cchp_file();

		# update a story's audio version, if using cepstral audio.
		if ($constants->{cepstral_audio}) {
			# fork a new script to render the audio, and
			# it will update the story_param table with the correct
			# pointers to the file
			system("$constants->{datadir}/sbin/audio-gen.pl $virtual_user $stoid &");
		}

		# Now call prog2nofile().
		$args = "$vu ssi=yes sid='$sid'$cchp_param";
		my $filename;
		if ($skid) {
			# XXXSKIN - more hardcoding (see Slash::Utility::Display)
			my $this_skinname = $skinname eq 'mainpage' ? 'articles' : $skinname;
			$args .= " section='$skinname'";
			$logmsg = "$me updated $stoid $skinname:$sid ($title)";
		} else {
			$logmsg = "$me updated $sid ($title)";
		}
		my($success, $stderr_text) = prog2nofile(
			"$basedir/article.pl",
			{
				args =>		$args,
				verbosity =>	verbosity(),
				handle_err =>	1,
			} );
		if (!$success) {
			$logmsg .= " success='$success'";
			$do_log ||= (verbosity() >= 1);
		}
		if ($stderr_text) {
			$stderr_text =~ s/\s+/ /g;
			$logmsg .= " stderr: '$stderr_text'";
			$do_log ||= (verbosity() >= 1);
			if ($stderr_text =~ /\b(ID \d+, \w+;\w+;\w+) :/) {
				# template error, skip
				slashdErrnote("template error updating $sid: $stderr_text");
				next STORIES_FRESHEN;
			}
		}

		# Now we extract what we need from the file we created
		my($cc, $hp) = _read_and_unlink_cchp_file($cchp_file, $cchp_param);
		if (defined($cc)) {
			$story_set{$stoid}{writestatus} = 'ok';
			$story_set{$stoid}{commentcount} = $cc;
			$story_set{$stoid}{hitparade} = $hp;
		}

		slashdLog($logmsg) if $logmsg && $do_log;
	}

	############################################################
	# bulk-update commentcount and hitparade
	############################################################

	$do_log = (verbosity() >= 2);
	$logmsg = "";
	my $min_cc = "";
	my $do_setstories = $do_all;
	if (!$do_setstories) {
		# We may still want to do it:  if one or more of the
		# stories affected has a small commentcount, we want
		# to get that updated.  Once numbers get larger,
		# small increments don't matter as much.
		my $stoids = [ keys %story_set ];
		$min_cc = $slashdb->getMinCommentcount($stoids);
		$do_setstories = 1 if $min_cc <= ($constants->{freshenup_small_cc} || 30);
	}
	if ($do_setstories) {
		for my $stoid (sort { $a <=> $b } keys %story_set) {
			my $options = undef;
			$options->{last_update} = $story_set{$stoid}{last_update}
				if $story_set{$stoid}{last_update};
			my $set_ok = $slashdb->setStory($stoid, $story_set{$stoid}, $options);
			if (!$set_ok) {
				$logmsg .= "; setStory($stoid) '$set_ok'";
				$do_log ||= (verbosity() >= 1);
			}
		}
		my $min_cc_msg = "";
		if (!$do_all) {
			$min_cc_msg = " (min_cc was $min_cc)";
		}
		slashdLog("setStory on " . scalar(keys %story_set) . " stories$min_cc_msg$logmsg")
			if $do_log && keys %story_set;
	}

};

sub freshenup_get_start_min {
	my($freq) = @_;
	return 0 if $freq < 2;
	my $hosthash = hex(substr(Digest::MD5::md5_hex($me . $main::hostname), 0, 4));
	my $frac = $hosthash / 65536;
	return int($freq * $frac);
}

sub _make_cchp_file {
	my $constants = getCurrentStatic();
	my $logdir = $constants->{logdir};
	my $cchp_prefix = catfile($logdir, "cchp.");
	my $cchp_fh = undef;
	my $cchp_suffix;
	my($cchp_file, $cchp_param) = ("", "");
	while (!$cchp_fh) {
		$cchp_file = File::Temp::mktemp("${cchp_prefix}XXXXXXXXXX");
		($cchp_suffix) = $cchp_file =~ /^\Q$cchp_prefix\E(.+)$/;
		$cchp_param = " cchp='$cchp_suffix'";
		if (!sysopen($cchp_fh, $cchp_file,
			O_WRONLY | O_EXCL | O_CREAT, # we must create it
			0600 # this must be 0600 for mild security reasons
		)) {
			$cchp_fh = undef; # just to be sure we repeat
			warn "could not create '$cchp_file', $!, retrying";
			Time::HiRes::sleep(0.2);
		}
	}
	close $cchp_fh;
	return ($cchp_file, $cchp_param);
}

sub _read_and_unlink_cchp_file {
	my($cchp_file, $cchp_param) = @_;
	my $constants = getCurrentStatic();
	my($cc, $hp) = (undef, undef);
	my $default_hp = join(",", ("0") x
		($constants->{comment_maxscore}-$constants->{comment_minscore}+1));

	# Now we extract what we need from the file we created
	Time::HiRes::sleep(0.5); # let filesystem settle
	if (!open(my $cchp_fh, "<", $cchp_file)) {
		warn "cannot open $cchp_file for reading, $!";
	} else {
		my $cchp = <$cchp_fh>;
		close $cchp_fh;
		$cchp = '' if !defined($cchp);
		if ($cchp && (($cc, $hp) = $cchp =~
			/count (\d+), hitparade (.+)$/m)) {
		} else {
			slashdLog("Commentcount/hitparade data was not"
				. " retrieved, reason unknown"
				. " (cchp: '$cchp' for param '$cchp_param' file '$cchp_file' exists '"
				. (-e $cchp_file) . "' len '"
				. (-s $cchp_file) . "')");
			($cc, $hp) = (undef, undef);
		}
	}
	unlink $cchp_file;
	return($cc, $hp);
}

1;
