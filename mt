#!/usr/bin/perl
# $Modified: Thu Jan 13 18:29:15 2000 by cwilson $

# majordomo: a person who speaks, makes arrangements, or takes charge
#	for another.
#
# Copyright 1992, D. Brent Chapman. See the Majordomo license agreement for
#   usage rights.
#
# $Source: /sources/cvsrepos/majordomo/majordomo,v $
# $Revision: 1.95 $
# $Date: 2000/01/13 17:29:31 $
# $Author: cwilson $
# $State: Exp $
#
# $Locker:  $

# set our path explicitly
# PATH it is set in the wrapper, so there is no need to set it here.
# until we run suid...
#$ENV{'PATH'} = "/bin:/usr/bin:/usr/ucb";

# Before doing anything else tell the world I am majordomo
# The mj_ prefix is reserved for tools that are part of majordomo proper.
$main'program_name = 'mj_majordomo';#';

# Read and execute the .cf file
$cf = $ENV{"MAJORDOMO_CF"} || "/etc/majordomo.cf"; 

while ($ARGV[0]) {	# parse for config file or default list
    if ($ARGV[0] =~ /^-C$/i) {	# sendmail v8 clobbers case
        $cf = "$ENV{'MAJORDOMO_CFDIR'}/$ARGV[1]" unless $ARGV[1] =~/\//;
        shift(@ARGV); 
        shift(@ARGV); 
    } elsif ($ARGV[0] eq "-l") {
        $deflist = $ARGV[1];
        shift(@ARGV); 
        shift(@ARGV); 
    } else {
	die "Unknown argument $ARGV[0]\n";
    }
}
if (! -r $cf) {
    die("$cf not readable; stopped");
}

require "$cf";

# Go to the home directory specified by the .cf file
chdir("$homedir") || die "chdir to $homedir failed, $!\n";

# If standard error is not attached to a terminal, redirect it to a file.
if (! -t STDERR) {
    close STDERR;
    open (STDERR, ">>$TMPDIR/majordomo.debug");
}

print STDERR "$0: starting\n" if $DEBUG;

# All these should be in the standard PERL library
unshift(@INC, $homedir);
require "ctime.pl";		# To get MoY definitions for month abbrevs
require "majordomo_version.pl";	# What version of Majordomo is this?
require "majordomo.pl";		# all sorts of general-purpose Majordomo subs
require "shlock.pl";		# NNTP-style file locking
require "config_parse.pl";	# functions to parse the config files

print STDERR "$0:  requires succeeded.  Setting defaults.\n" if $DEBUG; 

# Here's where the fun begins...
# check to see if the cf file is valid
die("\$listdir not defined. Is majordomo.cf being included correctly?")
	if !defined($listdir);

# Define all of the mailer properties:
# It is possible that one or both of $sendmail_command and $bounce_mailer
# are not defined, so we provide reasonable defaults.
$sendmail_command = "/usr/lib/sendmail"
  unless defined $sendmail_command;
$bounce_mailer = "$sendmail_command -f\$sender -t"
  unless defined $bounce_mailer;


&set_abort_addr($whoami_owner);
&set_mail_from($whoami);
&set_mail_sender($whoami_owner);
&set_mailer($bounce_mailer);

$majordomo_dont_reply = $majordomo_dont_reply 
    || '(mailer-daemon|uucp|listserv|majordomo)\@';

# where do we look for files, by default?
if (!defined($filedir)) {
    $filedir = $listdir;
}
if (!defined($filedir_suffix)) {
    $filedir_suffix = ".archive";
}

# what command do we use to generate an index, by default?
if (!defined($index_command)) {
    $index_command = "/bin/ls -lRL";
}

# where are we for FTP, by default?  (note: only set this if $ftpmail is set)
if (defined($ftpmail_address)) {
    if (!defined($ftpmail_location)) {
	$ftpmail_location = $whereami;
    }
}

print STDERR "$0:  done with defaults, parsing mail header.\n" if $DEBUG;

# Parse the mail header of the message, so we can figure out who to reply to
&ParseMailHeader(STDIN, *hdrs);

# Now we try to figure out who to send the replies to.
# $reply_to also becomes the default target for subscribe/unsubscribe
$reply_to = &RetMailAddr(*hdrs);

print STDERR "$0:  setting log file.\n" if $DEBUG;

# Set up the log file
&set_log($log, $whereami, "majordomo", $reply_to);

# if somebody has set $reply_to to be our own input address, there's a problem.
if (&addr_match($reply_to, $whoami)) {
    &abort( "$whoami punting to avoid mail loop.\n");
    exit 0;
}

if (! &valid_addr($reply_to)) {
    &abort( "$whoami: $reply_to is not a valid return address.\n");
    exit 2;
}

# robots should not reply to other robots...
if ($reply_to =~ m/$majordomo_dont_reply/i) {
      &abort( "$whoami: not replying to $1 to avoid mail loop.\n");
      exit 0;
}

if ($return_subject && defined $hdrs{'subject'}) {
	$sub_addin = ": " . substr($hdrs{'subject'}, 0, 40);
 } else {
	$sub_addin = '';
 }

print STDERR "$0:  some quick sanity checks on permissions.\n" if $DEBUG;

# do some sanity checking on permissions
# This bails out via abort if needed.
#
&check_permissions;

print STDERR "$0:  opening sendmail process.\n" if $DEBUG;

# Open the sendmail process to send the results back to the requestor
&sendmail(REPLY, $reply_to, "Majordomo results$sub_addin");

select((select(REPLY), $| = 1)[0]);

print STDERR "$0:  processing commands in message body.\n" if $DEBUG; 

# Process the rest of the message as commands
while (<>) {
    $approved = 0;			# all requests start as un-approved
    $quietnonmember = 0;		# show non-member on unsubscribe
    while ( /\\\s*$/ ) {		# if the last non-whitespace
	&chop_nl($_);			 # character is  '\', chop the nl
	s/\\\s*$/ /;			 # replace \ with space char
	$_ .= scalar(<>);		 # append the next line
	}
    print REPLY ">>>> $_";		# echo the line we are processing
    $_ = &chop_nl($_);			# strip any trailing newline
    s/^\s*#.*//;			# strip comments
    s/^\s+//;                           # strip leading whitespace
    s/\s+$//;                           # strip trailing whitespace
    s/\\ /\001/g;			# protected escaped whitepace	
    if (/^begin\s+\d+\s+\S+$/) {        # bail on MSMail uuencode attachments
      print REPLY "ATTACHMENT DETECTED; COMMAND PROCESSING TERMINATED.\n";
      last;
    }

    @parts = split(" ");		# split into component parts
    grep(s/\001/ /, @parts);		# replace protected whitespace with
					# whitespace
    $cmd = shift(@parts);		# isolate the command
    $cmd =~ tr/A-Z/a-z/;		# downcase the command
    if ($cmd eq "") { next; }		# skip blank lines
    # figure out what to do and do it
    # the "do_*" routines implement specific Majordomo commands.
    # they are all passed the same arguments: @parts.
    $count++;	# assume it's a valid command, so count it.
    if ($cmd eq "end") { print REPLY "END OF COMMANDS\n"; last; }
    elsif ($cmd =~ /^-/ &&
	   (!defined($hdrs{'content-type'}) ||
	    $hdrs{'content-type'} !~ /multipart/i))
      {
	# treat lines beginning with "-" as END only if this is NOT a MIME
	# multipart msg.  MIME messages should have "Content-Type:"
	# headers, and multipart messages should have the string
	# "multipart" somewhere in that header.  If we just look for
	# Content-Type: we trap messages with Content-Type: text/plain,
	# which is pretty common these days.
	print REPLY "END OF COMMANDS\n";
	last;
      }
    elsif ($cmd eq "subscribe") { &do_subscribe(@parts); }
    elsif ($cmd eq "unsubscribe") { &do_unsubscribe(@parts); }
    elsif ($cmd eq "signoff") { &do_unsubscribe(@parts); }
    elsif ($cmd eq "cancel") { &do_unsubscribe(@parts); }
    elsif ($cmd eq "approve") { &do_approve(@parts); }
    elsif ($cmd eq "passwd") { &do_passwd(@parts); }
    elsif ($cmd eq "which") { &do_which(@parts); }
    elsif ($cmd eq "who") { &do_who(@parts); }
    elsif ($cmd eq "info") { &do_info(@parts); }
    elsif ($cmd eq "newinfo") { &do_newinfo(@parts); }
    elsif ($cmd eq "intro") { &do_intro(@parts); }
    elsif ($cmd eq "newintro") { &do_newintro(@parts); }
    elsif ($cmd eq "config") { &do_config(@parts); }
    elsif ($cmd eq "newconfig") { &do_newconfig(@parts); }
    elsif ($cmd eq "writeconfig") { &do_writeconfig(@parts); }
    elsif ($cmd eq "mkdigest") { &do_mkdigest(@parts); }
    elsif ($cmd eq "lists") { &do_lists(@parts); }
    elsif ($cmd eq "help") { &do_help(@parts); }
    elsif ($cmd eq "get") { &do_get(@parts); }
    elsif ($cmd eq "index") { &do_index(@parts); }
    elsif ($cmd eq "auth") { &do_auth(@parts); }
    else {
	&squawk("Command '$cmd' not recognized.");
	$count--;	# if we get to here, it wasn't really a command
    }
}

# we've processed all the commands; let's clean up and go home
&done();

# Everything from here on down is subroutine definitions

sub do_subscribe {
    # figure out what list we are trying to subscribe to
    # and check to see if the list is valid
    local($sm) = "subscribe";
    local($list, $clean_list, @args) = &get_listname($sm, 1, @_);

    # figure out who's trying to subscribe, and check that it's a valid address
    local($subscriber) = join(" ", @args);
    if ($subscriber eq "") {
	$subscriber = $reply_to;
    }
    if (! &valid_addr($subscriber, $clean_list)) {
	&squawk("$sm: invalid address '$subscriber'");
	return 0;
    }

    local($FLAGIT);
    if ($clean_list ne "") {
	# The list is valid
	# parse its config file if needed

	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	local($sub_policy) = $config_opts{$clean_list,"subscribe_policy"};

	# check to see if this is a list with a 'confirm' subscribe policy, 
	# and check the cookie if so.
	#
	if (! $approved 
	    && (($sub_policy =~ /confirm/)
		&& (&gen_cookie($sm, $clean_list, $subscriber) ne $auth_info))) 
	  { 
	      # We want to send the stripped address in the confirmation
	      # message if strip = yes.
	      if (&cf_ck_bool($clean_list,"strip")) {
		  $subscriber = (&ParseAddrs($subscriber))[0];
	      }
	      &send_confirm("subscribe", $clean_list, $subscriber);
	      return 0; 
	  }
	
	
	# Check to see if this request is approved, or if the list is an
	#    auto-approve list, or if the list is an open list and the
	#    subscriber is the person making the request
	if ($approved 
	    || ($sub_policy =~ /auto/i &&
		# I don't think this check is doing the right thing.  Chan 95/10/19
		&check_and_request($sm, $clean_list, $subscriber, "check_only"))
	    || (($sub_policy !~ /closed/ )
		&&  &addr_match($reply_to, $subscriber, 
				(&cf_ck_bool($clean_list,"mungedomain") ? 2 : undef)))
	    ) {
	    # Either the request is approved, or the list is open and the
	    #    subscriber is the requester, so check to see if they're
	    #    already on the list, and if not, add them to the list.
	    # Lock and open the list first, even though &is_list_member()
	    #	 will reopen it read-only, to prevent a race condition
	    &lopen(LIST, ">>", "$listdir/$clean_list")
		|| &abort("Can't append to $listdir/$clean_list: $!");
	    if (&is_list_member($subscriber, $listdir, $clean_list)) {
		print REPLY "**** Address already subscribed to $clean_list\n";
		&log("DUPLICATE subscribe $clean_list $subscriber");
	    } else {
		if ( &cf_ck_bool($clean_list,"strip") ) {
		    print LIST &valid_addr($subscriber), "\n" ||
			&abort("Error writing $listdir/$clean_list: $!");
		} else {
		    print LIST $subscriber, "\n" ||
			&abort("Error writing $listdir/$clean_list: $!");
		}
		if (defined $deflist) {
		  print REPLY "Succeeded (to list $deflist).\n";
		}
		else {
		  print REPLY "Succeeded.\n";
		}
		&log("subscribe $clean_list $subscriber");
		# Send the new subscriber a welcoming message, and 
		# a notice of the new subscriber to the list owner
		if ( &cf_ck_bool($clean_list,"strip") ) {
		    local($clean_sub) = &valid_addr($subscriber);
		    &welcome($clean_list, $clean_sub);
		} else {
		    &welcome($clean_list, $subscriber);
		}
	    }
	    &lclose(LIST) || &abort("Error closing $listdir/$clean_list: $!");
	} else {
	    &check_and_request($sm, $clean_list, $subscriber);
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
}

sub do_unsubscribe_all {
    local(@parts) = @_;
    local($list);

    opendir(RD_DIR, $listdir) || &abort("opendir failed $!");
    @lists = grep(!/[^-\w]/, readdir(RD_DIR)); # skip non-list files (*.info, etc.)
    closedir(RD_DIR);

    $quietnonmember=1;

    foreach $list (sort @lists) {
	print REPLY "Doing 'unsubscribe $list ", join(' ', @parts), "'.\n"
	    if $DEBUG;
	&do_unsubscribe($list, @parts);
    }
}

sub do_unsubscribe {
    if ($_[0] =~ /^\*$/) {
	shift;
    	&do_unsubscribe_all(@_);
    	return 0;
    }
    local($match_count) = 0;
    local($match_length);
    # figure out what list we are trying to unsubscribe from
    # and check to see if the list is valid
    local($sm) = "unsubscribe";
    local($list, $clean_list, @args) = &get_listname($sm, 1, @_);

    # figure out who's trying to unsubscribe, and check it's a valid address
    local($subscriber) = join(" ", @args);
    if ($subscriber eq "") {
	$subscriber = $reply_to;
    }
    if (! &valid_addr($subscriber)) {
	&squawk("$sm: invalid address '$subscriber'");
	return 0;
    }

    print STDERR "do_unsubscribe: $subscriber from $clean_list\n" if $DEBUG;


    if ($clean_list ne "") {
	# The list is valid.
	# get configuration info
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	local($unsub_policy) = $config_opts{$clean_list,"unsubscribe_policy"};

	# Check to see if the subscriber really is subscribed to the list.
	if (! &is_list_member($subscriber, $listdir, $clean_list)) {
	    unless ($quietnonmember) {
		print REPLY <<"EOM";
**** unsubscribe: '$subscriber' is not a member of list '$list'.
**** contact "$list-approval\@$whereami" if you need help.
EOM
	    }
	    return 0;
	}
	
	print STDERR "do_unsubscribe: valid list, valid subscriber.\n"
	    if $DEBUG;

	# check to see if this is a list with a 'confirm' unsubscribe policy, 
	# and check the cookie if so and the subscriber is not the person
	# making the request. 
	#
	if (! $approved
	    && ! ((&addr_match($reply_to, $subscriber,
			       (&cf_ck_bool($clean_list,"mungedomain")
				? 2 : undef))))
	    && (($unsub_policy =~ /confirm/)
		&& (&gen_cookie($sm, $clean_list, $subscriber) ne $auth_info))) 
	  { 
	    # We want to send the stripped address in the confirmation
	    # message if strip = yes.
	    if (&cf_ck_bool($clean_list,"strip")) {
	      $subscriber = (&ParseAddrs($subscriber))[0];
	    }
	    &send_confirm("unsubscribe", $clean_list, $subscriber);
	    return 0; 
	  }
	
	# Check to see if this request is approved, if the unsub policy is
	# auto, or if the subscriber is the person making the request (even
	# on a closed list, folks can unsubscribe themselves without the
	# owner's approval).
	if ($approved
	    || ($unsub_policy =~ /auto/i &&
		&check_and_request($sm, $clean_list, $subscriber, "check_only"))

	    || ((&addr_match($reply_to, $subscriber,
			     (&cf_ck_bool($clean_list,"mungedomain") ? 2 : undef))))) {

	    # Either the request is approved, or the subscriber is the
	    # requester, so drop them from the list
	    &lopen(LIST, "", "$listdir/$clean_list") ||
		&abort("Can't open $listdir/$clean_list: $!");
	    (local($mode, $uid, $gid) = (stat(LIST))[2,4,5]) ||
		&abort("Can't stat listdir/$clean_list: $!");
	    open(NEW, ">$listdir/$clean_list.new") ||
		&abort("Can't open $listdir/$clean_list.new: $!");
	    chmod($mode, "$listdir/$clean_list.new") ||
		&abort("chmod($mode, \"$listdir/$clean_list.new\"): $!");
	    chown($uid, -1, "$listdir/$clean_list.new") ||
		&abort("chown($uid, $gid, \"$listdir/$clean_list.new\"): $!");
	    while (<LIST>) {
		if (! &addr_match($subscriber, $_,
				  (&cf_ck_bool($clean_list,"mungedomain") ? 2 : undef))) {
		    print NEW $_ ||
			&abort("Error writing $listdir/$clean_list.new: $!");
		} else {
		    $match_count++;
		    $match_length = length;
		    if ($match_count != 1) {
			&squawk("$sm: '$subscriber' matches multiple list members.");
			last;
		    }
		}
	    }
	    close(NEW) || &abort("Error closing $listdir/$clean_list.new: $!");
	    if ($match_count == 1) {
		if ((-s "$listdir/$clean_list.new") + $match_length !=
		    (-s "$listdir/$clean_list")) {
		    &abort("Unsubscribe failed: $listdir/$clean_list.new is wrong length!");
		}
		# we deleted exactly 1 name, so now we shuffle the files
		link("$listdir/$clean_list", "$listdir/$clean_list.old") ||
		    &abort("link(\"$listdir/$clean_list\", \"$listdir/$clean_list.old\"): $!");
		rename("$listdir/$clean_list.new", "$listdir/$clean_list") ||
		    &abort("rename(\"$listdir/$clean_list.new\", \"$listdir/$clean_list\"): $!");
		unlink("$listdir/$clean_list.old");
		if (defined $deflist) {
		  print REPLY "Succeeded (from list $deflist).\n";
		}
		elsif ($quietnonmember) {
		  print REPLY "Succeeded (from list $clean_list).\n";
		}
		else {
		  print REPLY "Succeeded.\n";
		}
		&log("unsubscribe $clean_list $subscriber");
		if ( &cf_ck_bool($list,"announcements")) {
		&sendmail(BYE, "$clean_list-approval\@$whereami",
			  "UNSUBSCRIBE $clean_list $subscriber");
		print BYE "$subscriber has unsubscribed from $clean_list.\n";
		print BYE "No action is required on your part.\n";
		close(BYE);
		}
	    }
	    elsif ($match_count == 0) {
		print REPLY "**** No matches found for '$subscriber'\n";
	    }
	    else {
		print REPLY "**** FAILED.\n";
	    }
	    unlink("$listdir/$clean_list.new");
	    &lclose(LIST);
	} else {
	    print STDERR "do_unsubscribe: authorization failed, calling check_and_request.\n" if $DEBUG;
	    &check_and_request($sm, $clean_list, $subscriber);
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
}

sub do_auth {
    # Check to see we've got all the arguments; the address is allowed to
    # contain spaces, so since our argument list was split on spaces we
    # have to join them back together.
    local($auth_info, $cmd, $list, @sub) = @_;
    if ( !length($auth_info) 
	|| ($cmd ne 'subscribe'
	    && $cmd ne 'unsubscribe') # can only authorize [un]subscribes at the moment
       ) {
	&squawk("auth: needs key");
	return 0;
    }
    $sub = join(' ',@sub);
    if ( $cmd eq "subscribe" ) {
      &do_subscribe($list, $sub);
    }
    elsif ( $cmd eq "unsubscribe" ) {
      &do_unsubscribe($list, $sub);
    }


}

sub do_approve {
    # Check to see we've got all the arguments
    local($sm) = "approve";
    local($passwd, $cmd);
    ($passwd = shift)	|| &squawk("$sm: needs passwd");
    ($cmd    = shift)	|| &squawk("$sm: which command?");
    $cmd =~ tr/A-Z/a-z/;	# downcase the command
    # Check to see if the list is valid or use default list.
    # and check to see if we've got a valid list
    local($list, $clean_list, @args) = &get_listname($sm, -1, @_);

    if ($clean_list ne "") {
	# get the config info for the command
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	# The list is valid; now check to see if the password is
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	    # The password is valid, so set "approved" and do the request
	    $approved = 1;
	    if ($cmd eq "subscribe") {
		local($subscriber);
		($subscriber = join(" ",@args))	|| &squawk("$sm: who?");
		&log("approve PASSWORD subscribe $clean_list $subscriber");
		&do_subscribe($clean_list, $subscriber);
	    } elsif ($cmd eq "unsubscribe") {
		local($subscriber);
		($subscriber = join(" ",@args))	|| &squawk("$sm: who?");
		&log("approve PASSWORD unsubscribe $clean_list $subscriber");
		&do_unsubscribe($clean_list, $subscriber);
	    } elsif ($cmd eq "get" 
		     || $cmd eq "index" 
		     || $cmd eq "info"
		     || $cmd eq "intro"
		     || $cmd eq "who"
		     || $cmd eq "which") {
		&log("approve PASSWORD $cmd $clean_list " . join(" ", @args));
		$sub = "do_$cmd";
		&$sub($clean_list, @args);
	    } else {
		# you can only approve the above
		&squawk("$sm: invalid command '$cmd'");
	    }
	} else {
	    &squawk("$sm: invalid list or password.");
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
}
	
sub do_passwd {
    # check to see that we've got all the arguments
    # and check to see if we've got a valid list
    local($sm) = "passwd";
    local($list, $clean_list, $passwd, $new_passwd) = &get_listname($sm, 2, @_);
    &squawk("$sm: need old password") unless $passwd;
    &squawk("$sm: need new password") unless $new_passwd;

    if ($clean_list eq "") {
	&squawk("$sm: invalid list '$list'");
	return;
    }
    # We've got a valid list; now see if the old password is valid
    # get the config info for the command
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

    if (&valid_passwd($listdir, $clean_list, $passwd)) {
	# The old password is correct, so make sure the new one isn't null
	if ($new_passwd eq "") {
	    &squawk("$sm: null 'new_passwd'.");
	    return;
	}
	# The new password is valid, too, so write it.
	local($mode, $uid, $gid) =
	    (stat("$listdir/$clean_list.passwd"))[2,4,5];
	$mode = (0660) if !$mode;
	if (&lopen(PASSWD, ">", "$listdir/$clean_list.passwd")) {
	    print PASSWD $new_passwd, "\n";
	    &lclose(PASSWD);
	    # set the file mode appropriately
	    chmod($mode, "$listdir/$clean_list.passwd");
	    chown($uid, -1, "$listdir/$clean_list.passwd") if defined($uid);
	    print REPLY "Password changed.\n";
	} else {
	    &abort("Can't open $listdir/$clean_list.passwd: $!");
	}
	&log("passwd $clean_list OLD NEW");
    } else {
	print REPLY "**** Sorry; old password incorrect.\n";
	&log("FAILED passwd $clean_list OLD NEW");
    }
}

sub do_which {
    local($subscriber) = join(" ", @_) || &valid_addr($reply_to);
    local($count, $per_list_hits) = 0;
    # Tell the requestor which lists they are on by reading through all
    # the lists, comparing their address to each address from each list
    print REPLY "The string '$subscriber' appears in the following\n";
    print REPLY "entries in lists served by $whoami:\n\n";

    opendir(RD_DIR, $listdir) || &abort("opendir failed $!");
    @lists = readdir(RD_DIR);
    closedir(RD_DIR);

    foreach (sort @lists) {
	/[^-_0-9a-zA-Z]/ && next;	# skip non-list files (*.info, etc.)
	$list = $_;

	# get configuration info
	&get_config($listdir, $_) if !&cf_ck_bool($_, '', 1);

	# access check
	# 
	next if ! &access_check("which", $reply_to, $listdir, $list);

	open(LIST, "$listdir/$list") ||
	    &abort("Can't open list $listdir/$list");
	while (<LIST>) {

	    if (! $approved 
		&& $max_which_hits 
		&& $max_which_hits < $per_list_hits) {
		print REPLY "Maximum number of hits ($max_which_hits) exceeded\n";
		last;
	    }

	    $_ = &chop_nl($_);
	    if (&addr_match($_, $subscriber, 1)) {
		if ($count == 0) {
		    printf REPLY "%-23s %s\n", "List", "Address";
		    printf REPLY "%-23s %s\n", "====", "=======";
		}
		printf REPLY "%-23s %s\n", $list, $_;
		$count++;
		$per_list_hits++;
	    }
	}
	close(LIST);
    }
    if ($count == 0) {
	print REPLY "**** No matches found\n";
    }
    print REPLY "\n";
    &log("which $subscriber");
    return 1;
}

sub do_who {
    # Make sure we've got the right arguments
    # and check to see if we've got a valid list
    local($sm) = "who";
    local($list, $clean_list) = &get_listname($sm, 0, @_);
    local($counter) = 0;

    # Check to see that the list is valid
    if ($clean_list ne "") {
	# The list is valid, so now check make sure that it's not a private
	# list, or if it is, that the requester is on the list.
	# get configuration info
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	if ( !$approved 
	    && $config_opts{$clean_list, 'who_access'} =~ /closed/ ) {
	    print REPLY "**** Command disabled.\n";
	    return 0;
	}
	    
	if ( !$approved 
	    && ! &access_check("who", $reply_to, $listdir, $clean_list)) {
	    print REPLY "**** List '$clean_list' is a private list.\n";
	    print REPLY "**** Only members of the list can do a 'who'.\n";
	    print REPLY "**** You [ $reply_to ] aren't a member of list '$clean_list'.\n";
	    return 0;
	}
	#open it up and tell who's on it
	print REPLY "Members of list '$clean_list':\n\n";
	if (&lopen(LIST, "", "$listdir/$clean_list")) {
	    while (<LIST>) {
		print REPLY $_;
		$counter++;
	    }
	    &lclose(LIST);
	    printf REPLY "\n%s subscriber%s\n\n", ($counter ? $counter : "No"),
		($counter == 1 ? "" : "s");
	    &log("who $clean_list");
	} else {
	    &abort("Can't open $listdir/$clean_list: $!");
	}
    } else {
	print REPLY "**** who: no such list '$list'\n";
    }
}

sub do_info {
    # Make sure we've got the arguments we need
    # and Check that the list is OK
    local($sm) = "info";
    local($list, $clean_list) = &get_listname($sm, 0, @_);

    if ($clean_list ne "") {
	# The list is OK, so give the info, or a message that none is available
	# get configuration info
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	local($allow);
	
	# check access
	$allow = &access_check("info", $reply_to, $listdir, $clean_list);
	
	if ((local($passwd) = shift) &&
	    &valid_passwd($listdir, $clean_list, $passwd)) {
	    $allow = 1;		# The password is valid, so show info
	}
	if ($allow &&
	    &lopen(INFO, "", "$listdir/$clean_list.info")) {
	    while (<INFO>) {
		print REPLY $_;
	    }
	    print REPLY "\n[Last updated ", &chop_nl(&ctime((stat(INFO))[9])),
		"]\n" if !&cf_ck_bool($clean_list,"date_info");
	    &lclose(INFO);
	} else {
	    print REPLY "#### No info available for $clean_list.\n";
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
    &log("info $clean_list");
}

sub do_newinfo {
    # Check to make sure we've got the right arguments
    # and Check that the list is valid
    local($sm) = "newinfo";
    local($list, $clean_list, $passwd) = &get_listname($sm, 1, @_);
    &squawk("$sm: needs password") unless $passwd;

    if ($clean_list ne "") {
	&get_config($listdir, $clean_list) if !&cf_ck_bool($clean_list, '', 1);
	# The list is valid, so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	    # The password is valid, so write the new info
	    local($mode, $uid, $gid) =
		(stat("$listdir/$clean_list.info"))[2,4,5];
	    $mode = (0664) if !$mode;
	    if (&lopen(INFO, ">", "$listdir/$clean_list.info")) {
	        print INFO "[Last updated on: ", &chop_nl(&ctime(time())),
			 "]\n" if &cf_ck_bool($clean_list,"date_info");
		while (<>) {
		    $_ = &chop_nl($_);
		    if ($_ eq "EOF") {
			last;
		    }
		    print INFO $_, "\n";
		}
		&lclose(INFO);
		if (-s "$listdir/$clean_list.info" > 0) {
		  chmod($mode, "$listdir/$clean_list.info");
		  chown($uid, -1, "$listdir/$clean_list.info")
		    if defined($uid);
		}
		else {
		  unlink("$listdir/$clean_list.info");
		}

		print REPLY "New info for list $clean_list accepted.\n";
		&log("newinfo $clean_list PASSWORD");
	    } else {
		&abort("Can't write $listdir/$clean_list.info: $!");
	    }
	} else { 
	    &squawk("$sm: invalid password.");
	    &log("FAILED newinfo $clean_list PASSWORD");
	    while (<>) {
		$_ = &chop_nl($_);
		if ($_ eq "EOF") {
		    last;
		}
	    }
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
        while (<>) {
	    $_ = &chop_nl($_);
	    if ($_ eq "EOF") {
	        last;
	    }
        }
    }
}

sub do_intro {
    # Make sure we've got the arguments we need
    # and Check that the list is OK
    local($sm) = "intro";
    local($list, $clean_list) = &get_listname($sm, 0, @_);

    if ($clean_list ne "") {
	# The list is OK, so give the intro, or a message that none is available
	# get configuration info
	&get_config($listdir, $clean_list)
			if !&cf_ck_bool($clean_list, '', 1);
	local($allow) = 0;
	
	# check access
	$allow = &access_check("intro", $reply_to, $listdir, $clean_list);

	if ((local($passwd) = shift) &&
	       &valid_passwd($listdir, $clean_list, $passwd)) {
	    $allow = 1;		# The password is valid, so show info
	}
	if ($allow &&
	    &lopen(INFO, "", "$listdir/$clean_list.intro")) {
	    while (<INFO>) {
		print REPLY $_;
	    }
	    print REPLY "\n[Last updated ", &chop_nl(&ctime((stat(INFO))[9])),
		"]\n" if !&cf_ck_bool($clean_list,"date_intro");
	    &lclose(INFO);
	} else {
	    print REPLY "#### No intro available for $clean_list.\n";
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
    &log("intro $clean_list");
}
sub do_newintro {
    # Check to make sure we've got the right arguments
    # and Check that the list is valid
    local($sm) = "newintro";
    local($list, $clean_list, $passwd) = &get_listname($sm, 1, @_);
    &squawk("$sm: needs password") unless $passwd;

    if ($clean_list ne "") {
	&get_config($listdir, $clean_list) if !&cf_ck_bool($clean_list, '', 1);
	# The list is valid, so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	    # The password is valid, so write the new intro
	    if (&lopen(INFO, ">", "$listdir/$clean_list.intro")) {
	        print INFO "[Last updated on: ", &chop_nl(&ctime(time())),
			 "]\n" if &cf_ck_bool($clean_list,"date_intro");
		while (<>) {
		    $_ = &chop_nl($_);
		    if ($_ eq "EOF") {
			last;
		    }
		    print INFO $_, "\n";
		}
		&lclose(INFO);
		if (-s "$listdir/$clean_list.intro" > 0) {
		  chmod(0664, "$listdir/$clean_list.intro");
		}
		else {
		  unlink("$listdir/$clean_list.intro");
		}
		print REPLY "New intro for list $clean_list accepted.\n";
		&log("newintro $clean_list PASSWORD");
	    } else {
		&abort("Can't write $listdir/$clean_list.intro: $!");
	    }
	} else {
	    &squawk("$sm: invalid password.");
	    &log("FAILED newintro $clean_list PASSWORD");
	    while (<>) {
		$_ = &chop_nl($_);
		if ($_ eq "EOF") {
		    last;
		}
	    }
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
        while (<>) {
	    $_ = &chop_nl($_);
	    if ($_ eq "EOF") {
	        last;
	    }
        }
    }
}
sub do_config {
    # Check to make sure we've got the right arguments
    # and Check that the list is valid
    local($sm) = "config";
    local($list, $clean_list, $passwd) = &get_listname($sm, 1, @_);
    &squawk("$sm: needs password") unless $passwd;

    if ($clean_list ne "") {
	# The list is valid, parse the config file
	&set_lock("$listdir/$clean_list.config.LOCK") ||
	    &abort( "Can't get lock for $listdir/$clean_list.config");
	&get_config($listdir, $clean_list, "locked")
	    if !&cf_ck_bool($clean_list, '', 1);

	#so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	# The password is valid, so send the new config if it exists

	    if (open(LCONFIG, "$listdir/$clean_list.config")) {
	    while (<LCONFIG>) {
		print REPLY $_;
	    }
	    print REPLY "\n#[Last updated ", 
			&chop_nl(&ctime((stat(LCONFIG))[9])), "]\n";
	    close(LCONFIG) ||
		print REPLY "Error writing config for $clean_list: $!";
	   
	    } else {
	    print REPLY "#### No config available for $clean_list.\n";
	    }
        } else {
	    &squawk("$sm: invalid password.");
	    &log("FAILED config $clean_list PASSWORD");
        }
	&free_lock("$listdir/$clean_list.config.LOCK");
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
    &log("config $clean_list");
}

sub do_newconfig {
    # Check to make sure we've got the right arguments
    # and Check that the list is valid
    local($sm) = "newconfig";
    local($list, $clean_list, $passwd) = &get_listname($sm, 1, @_);
    &squawk("$sm: needs password") unless $passwd;

    if ($clean_list ne "") {
	# The list is valid, parse the config file
	&set_lock("$listdir/$clean_list.config.LOCK") ||
	    &abort( "Can't get lock for $listdir/$clean_list.config");
	&get_config($listdir, $clean_list, "locked")
	    if !&cf_ck_bool($clean_list, '', 1);

	# so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	    # The password is valid, so write the new config
	    # off to the side to validate it.
	    local($oldumask) = umask($config_umask);
	    if (open(NCONFIG, ">$listdir/$clean_list.new.config")) {
		while (<>) {
		    $_ = &chop_nl($_);
		    if ($_ eq "EOF") {
			last;
		    }
		    print NCONFIG $_, "\n";
		}
		close(NCONFIG) ||
		    &abort("Can't write $listdir/$clean_list.config: $!");
		umask($oldumask);

		if ( &get_config($listdir, "$clean_list.new", "locked"))  {
		    unlink "$listdir/$clean_list.new.config";
		    &free_lock("$listdir/$clean_list.config.LOCK");
		    print REPLY "The new config file for $clean_list was NOT accepted because:\n";
		    print REPLY @config'errors;
	            &log("FAILED (syntax) newconfig $clean_list PASSWORD");
		    return (1);
		} 

		$rename_fail = 0;
		if ( !rename("$listdir/$clean_list.config",
			    "$listdir/$clean_list.old.config") ) {
		    print REPLY "rename current -> old failed $!";
		    $rename_fail = 1;
		} 
		elsif ( !rename("$listdir/$clean_list.new.config",
			     "$listdir/$clean_list.config")) {
		    print REPLY "rename new -> current failed $!";
		    $rename_fail = 1;
		} 

		print REPLY "New config for list $clean_list accepted.\n"
			if !$rename_fail;

		&log("newconfig $clean_list PASSWORD");
		&get_config($listdir, $clean_list, "locked");
	    } else {
		&abort("Can't write $listdir/$clean_list.config: $!");
	    }
	} else {
	    &squawk("$sm: invalid password.");
	    &log("FAILED newconfig $clean_list PASSWORD");
	    while (<>) {
		$_ = &chop_nl($_);
		if ($_ eq "EOF") {
		    last;
		}
	    }
	}
	&free_lock("$listdir/$clean_list.config.LOCK");

    } else {
	&squawk("$sm: unknown list '$list'.");
        while (<>) {
	    $_ = &chop_nl($_);
	    if ($_ eq "EOF") {
		    last;
	    }
	}
    }
}

sub do_writeconfig {
    # Check to make sure we've got the right arguments
    # and Check that the list is valid
    local($sm) = "writeconfig";
    local($list, $clean_list, $passwd) = &get_listname($sm, 1, @_);
    &squawk("$sm: needs password") unless $passwd;

    if ($clean_list ne "") {
	# The list is valid, parse the config file
	&set_lock("$listdir/$clean_list.config.LOCK") ||
	    &abort( "Can't get lock for $listdir/$clean_list.config");
	&get_config($listdir, $clean_list, "locked")
	    if !&cf_ck_bool($clean_list, '', 1);

	# so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	    # The password is valid, so write current config
		&config'writeconfig($listdir, $clean_list);
		print REPLY "wrote new config for list $clean_list.\n";
		&log("writeconfig $clean_list PASSWORD");
	} else {
	    &squawk("$sm: invalid password.");
	    &log("FAILED writeconfig $clean_list PASSWORD");
	}
	&free_lock("$listdir/$clean_list.config.LOCK");
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
}

sub do_mkdigest { 
    # Check to make sure we've got the right arguments
    local($list, $clean_list, @args) = &get_listname($sm, -1, @_);

    # We allow the specification of the outgoing alias for the digest so
    # that list owners can change it to be something secret, but we have to
    # remain backwards compatible, so we allow 2 or 3 args.
    local($list_outgoing);
    if ($#args == 1) {  # Called with 2 or 3 args, one already shifted off
      $list_outgoing = shift @args;
    }
    else {
      $list_outgoing = "$list-outgoing";
    }
    local($passwd);
    ($passwd = shift @args)	|| &squawk("$sm: needs password");
    local(@digest_errors) = ();
    # Check that the list is valid
    local($clean_list) = &valid_list($listdir, $list);
    if ($clean_list ne "") {
	# The list is valid, parse the config file
	&get_config($listdir, $clean_list) if !&cf_ck_bool($clean_list, '', 1);

	#so check the password
	if (&valid_passwd($listdir, $clean_list, $passwd)) {
	# The password is valid, so run digest

    	    open(DIGEST, 
		"$homedir/digest -m -C -l $list $list_outgoing 2>&1 |");
	    @digest_errors = <DIGEST>;
	    close(DIGEST);

	    if ( $? == 256  ) {
		print REPLY "*** mkdigest: Failure on exec of digest $!\n";
		print REPLY @digest_errors;
	    	&log("FAILED mkdigest $list: exec error");
	    } else {
		if ($? != 0 ) { # hey the exec worked
		   print REPLY "*** digest: failed errors follow\n";
		   print REPLY @digest_errors;
	    	   &log("FAILED mkdigest $list: errors during digest");
	        } else {
		    print REPLY @digest_errors;
	 	    &log("mkdigest $clean_list");
	        }
            }
        } else {
	    &squawk("$sm: invalid password.");
	    &log("FAILED mkdigest $clean_list PASSWORD");
        }
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
}

sub do_lists {
    # Tell the requester what lists we serve
    local($list);
    local($reply_addr) = &ParseAddrs($reply_to);

    select((select(REPLY), $| = 1)[0]);

    print REPLY "$whoami serves the following lists:\n\n";

    opendir(RD_DIR, $listdir) || &abort("opendir failed $!");
    @lists = readdir(RD_DIR);
    closedir(RD_DIR);

    foreach (sort @lists) {
	$list = $_;
	$list =~ /[^-_0-9a-zA-Z]/ && next; # skip non-list files (*.info, etc.)
	next if /^(RCS|CVS|core)$/;	# files and directories to ignore
	next if (-d "$listdir/$list"); # skip directories

	&get_config($listdir, $list) if !&cf_ck_bool($list, '', 1);

	if (    ($'config_opts{$list, 'advertise'} ne '') 
	     || ($'config_opts{$list, 'noadvertise'} ne '') ) {

	    local(@array, $i);
	    local($result) = 0;
	    local($_) = $reply_addr;
		
		if ($'config_opts{$list, 'advertise'} ne '') {
		   @array = split(/\001/,$'config_opts{$list, 'advertise'});
		   foreach $i (@array) {
		      $result = 1, last if (eval $i); # Expects $_ = $reply_addr
		   }
                } else { $result = 1; }

		@array = ();
		if ($result) {
		   @array = split(/\001/,$'config_opts{$list, 'noadvertise'});

		   foreach $i (@array) {
		      $result = 0, last if (eval $i); # Expects $_ = $reply_addr
                   }
		}


	    $result  = &is_list_member($reply_to, $listdir, $list)
		if ! $result;

		printf REPLY "  %-23s %-.56s\n", $list,
			$config_opts{$list, 'description'} if $result;
	} else {
		printf REPLY "  %-23s %-.56s\n", $list,
			$config_opts{$list, 'description'};
	}

    }
    print REPLY "\nUse the 'info <list>' command to get more information\n";
    print REPLY "about a specific list.\n";
    &log("lists");
}

# Subroutines do_get and do_index handle files for the requestor.
# Majordomo will look for the files in directory "$filedir/$list$filedir_suffix"
# You need to specify a directory in majordomo.cf such as:
#	$filedir = "/usr/local/mail/files";
#	$filedir_suffix = "";
# to have it check directory "/usr/local/mail/files/$list" or
#	$filedir = "$listdir";
#	$filedir_suffix = ".archive";
# to have it check directory "$listdir/$list.archive".
#
# If you want majordomo to do the basic file handling, don't
# set the ftpmail options.  Set the index command using:
#	$index_command = "/bin/ls -lRL";
#
# If you want FTPMail to do the file handling, also put in:
#	$ftpmail_location = "$whereami"
#	$ftpmail_address = "ftpmail@$whereami";
#  or
#	$ftpmail_address = "ftpmail@decwrl.dec.com";
# as appropriate.
#
# Note that "$ftpmail_location" might NOT be the same as "$whereami";
# for instance, at GreatCircle.COM, "$whereami" is "GreatCircle.COM" (which
# is an MX record) but "$ftpmail_location" needs to be "FTP.GreatCircle.COM"
# (which is an alias for actual machine)

sub do_get {
    # Make sure we've got the arguments we need
    # and Check that the list is OK
    local($sm) = "get";
    local($list, $clean_list, $filename) = &get_listname($sm, 1, @_);
    &squawk("$sm: which file?") unless $filename;

    if ($clean_list ne "") {
	# The list is valid, so now check make sure that it's not a private
	# list, or if it is, that the requester is on the list.
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);

	if ( !$approved
	    && $config_opts{$clean_list, 'get_access'} =~ /closed/ ) {
	    print REPLY "**** Command disabled.\n";
	    return 0;
	}

	if ( !$approved 
	    && ! &access_check("get", $reply_to, $listdir, $clean_list)) {
	    print REPLY "**** List '$clean_list' is a private list.\n";
	    print REPLY "**** Only members of the list can do a 'get'.\n";
	    print REPLY "**** You aren't a member of list '$clean_list'.\n";
	    return 0;
	}
	# The list is OK, so check the file name
	local($clean_file) = &valid_filename($filedir, $clean_list,
	    $filedir_suffix, $filename);
	if (defined($clean_file)) {
	    # the file name was OK and exists
	    # see if file handling is done by ftpmail
	    if (defined($ftpmail_address)) {
		# File handling is done by ftpmail
		if ($ftpmail_location eq "") {$ftpmail_location = $whereami; };
		&sendmail(FTPMAILMSG, $ftpmail_address, "get $filename",
		    $reply_to);
		print FTPMAILMSG "open $ftpmail_location\n";
		print FTPMAILMSG "cd $filedir/$clean_list$filedir_suffix\n";
		print FTPMAILMSG "get $filename\n";
		close (FTPMAILMSG);
		print REPLY "'get' request forwarded to $ftpmail_address\n";
	    } else {
		# file handling is done locally.
		if (&lopen(GETFILE, " ", "$clean_file")) {
		    # Set up the sendmail process to send the file
		    &sendmail(GETFILEMSG, $reply_to,
			"Majordomo file: list '$clean_list' file '$filename'");
		    while (<GETFILE>) {
			print GETFILEMSG $_;
		    }
		    # close (and thereby send) the file
		    close(GETFILEMSG);
		    &lclose(GETFILE);
		    print REPLY <<"EOM";
List '$clean_list' file '$filename'
is being sent as a separate message.
EOM
		} else {
		    print REPLY
		    "#### No such file '$filename' for list '$clean_list'\n";
		}
	    }
	} else {
	    &squawk("$sm: invalid file '$filename' for list '$clean_list'.");
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
    &log("get $clean_list $filename");
}

sub do_index {
    # Make sure we've got the arguments we need
    # and Check that the list is OK
    local($sm) = "index";
    local($list, $clean_list) = &get_listname($sm, 0, @_);

    if ($clean_list ne "") {
	&get_config($listdir, $clean_list) 
			if !&cf_ck_bool($clean_list, '', 1);
	# The list is valid, so now check make sure that it's not a private
	# list, or if it is, that the requester is on the list.
	if ( !$approved 
	    && $config_opts{$clean_list, 'index_access'} =~ /closed/ ) {
	    print REPLY "**** Command disabled.\n";
	    return 0;
	}

	if ( !$approved 
	    && ! &access_check("index", $reply_to, $listdir, $clean_list)) {
	    print REPLY "**** List '$clean_list' is a private list.\n";
	    print REPLY "**** Only members of the list can do an 'index'.\n";
	    print REPLY "**** You aren't a member of list '$clean_list'.\n";
	    return 0;
	}
	# The list is OK; see if file handling is done by ftpmail
	if (defined($ftpmail_address)) {
	# File handling is done by ftpmail
	    &sendmail(FTPMAILMSG, $ftpmail_address, "index $clean_list", $reply_to);
	    print FTPMAILMSG "open $ftpmail_location\n";
	    print FTPMAILMSG "cd $filedir/$clean_list$filedir_suffix\n";
	    print FTPMAILMSG "dir\n";
	    close (FTPMAILMSG);
	    print REPLY "'index' request forwarded to $ftpmail_address\n";
	} else {
	    if (-d "$filedir/$clean_list$filedir_suffix") {
		if (chdir "$filedir/$clean_list$filedir_suffix") {
		    open(INDEX,"$index_command|")
		      || &abort("Can't fork to run $index_command, $!");
		    while (<INDEX>) {
			print REPLY $_;
		    }
		    unless (close INDEX) {
			&bitch("Index command $index_command failed.\n$! $?");
			&squawk("$sm: index command failed");
		    }
		}
		else {
		    &bitch("Cannot chdir to $filedir/$clean_list$filedir_suffix to build index\n$!");
		    &squawk("$sm: index command failed");
		}
	    } else {
		print REPLY "#### No files available for $clean_list.\n";
	    }
	}
    } else {
	&squawk("$sm: unknown list '$list'.");
    }
    &log("index $list");
    chdir("$homedir");
}

sub do_help {
    print STDERR "$0:  do_help()\n" if $DEBUG;

    local($list4help) = $majordomo_request ? "[<list>]" : "<list>";

    local($listrequest) =  " or to \"<list>-request\@$whereami\".\n";
    $listrequest .= "\nThe <list> parameter is only optional if the ";
    $listrequest .= "message is sent to an address\nof the form ";
    $listrequest .= "\"<list>-request\@$whereami\".";

    $listrequest = "." unless $majordomo_request;

    print REPLY <<"EOM"; 

This help message is being sent to you from the Majordomo mailing list
management system at $whoami.

This is version $majordomo_version of Majordomo.

If you're familiar with mail servers, an advanced user's summary of
Majordomo's commands appears at the end of this message.

Majordomo is an automated system which allows users to subscribe
and unsubscribe to mailing lists, and to retrieve files from list
archives.

You can interact with the Majordomo software by sending it commands
in the body of mail messages addressed to "$whoami".
Please do not put your commands on the subject line; Majordomo does
not process commands in the subject line.

You may put multiple Majordomo commands in the same mail message.
Put each command on a line by itself.

If you use a "signature block" at the end of your mail, Majordomo may
mistakenly believe each line of your message is a command; you will
then receive spurious error messages.  To keep this from happening,
either put a line starting with a hyphen ("-") before your signature,
or put a line with just the word

	end

on it in the same place.  This will stop the Majordomo software from
processing your signature as bad commands.

Here are some of the things you can do using Majordomo:

I.	FINDING OUT WHICH LISTS ARE ON THIS SYSTEM

To get a list of publicly-available mailing lists on this system, put the
following line in the body of your mail message to $whoami:

	lists

Each line will contain the name of a mailing list and a brief description
of the list.

To get more information about a particular list, use the "info" command,
supplying the name of the list.  For example, if the name of the list 
about which you wish information is "demo-list", you would put the line

	info demo-list

in the body of the mail message.

II.	SUBSCRIBING TO A LIST

Once you've determined that you wish to subscribe to one or more lists on
this system, you can send commands to Majordomo to have it add you to the
list, so you can begin receiving mailings.

To receive list mail at the address from which you're sending your mail,
simply say "subscribe" followed by the list's name:

	subscribe demo-list

If for some reason you wish to have the mailings go to a different address
(a friend's address, a specific other system on which you have an account,
or an address which is more correct than the one that automatically appears 
in the "From:" header on the mail you send), you would add that address to
the command.  For instance, if you're sending a request from your work
account, but wish to receive "demo-list" mail at your personal account
(for which we will use "jqpublic\@my-isp.com" as an example), you'd put
the line

	subscribe demo-list jqpublic\@my-isp.com

in the mail message body.

Based on configuration decisions made by the list owners, you may be added 
to the mailing list automatically.  You may also receive notification
that an authorization key is required for subscription.  Another message
will be sent to the address to be subscribed (which may or may not be the
same as yours) containing the key, and directing the user to send a
command found in that message back to $whoami.  (This can be
a bit of extra hassle, but it helps keep you from being swamped in extra
email by someone who forged requests from your address.)  You may also
get a message that your subscription is being forwarded to the list owner
for approval; some lists have waiting lists, or policies about who may
subscribe.  If your request is forwarded for approval, the list owner
should contact you soon after your request.

Upon subscribing, you should receive an introductory message, containing
list policies and features.  Save this message for future reference; it
will also contain exact directions for unsubscribing.  If you lose the
intro mail and would like another copy of the policies, send this message
to $whoami:

	intro demo-list

(substituting, of course, the real name of your list for "demo-list").

III.	UNSUBSCRIBING FROM MAILING LISTS

Your original intro message contains the exact command which should be
used to remove your address from the list.  However, in most cases, you
may simply send the command "unsubscribe" followed by the list name:

	unsubscribe demo-list

(This command may fail if your provider has changed the way your
address is shown in your mail.)

To remove an address other than the one from which you're sending
the request, give that address in the command:

	unsubscribe demo-list jqpublic\@my-isp.com

In either of these cases, you can tell $whoami to remove
the address in question from all lists on this server by using "*"
in place of the list name:

	unsubscribe *
	unsubscribe * jqpublic\@my-isp.com

IV.	FINDING THE LISTS TO WHICH AN ADDRESS IS SUBSCRIBED

To find the lists to which your address is subscribed, send this command
in the body of a mail message to $whoami:

	which

You can look for other addresses, or parts of an address, by specifying
the text for which Majordomo should search.  For instance, to find which
users at my-isp.com are subscribed to which lists, you might send the
command

	which my-isp.com

Note that many list owners completely or fully disable the "which"
command, considering it a privacy violation.

V.	FINDING OUT WHO'S SUBSCRIBED TO A LIST

To get a list of the addresses on a particular list, you may use the
"who" command, followed by the name of the list:

	who demo-list

Note that many list owners allow only a list's subscribers to use the
"who" command, or disable it completely, believing it to be a privacy
violation.

VI.	RETRIEVING FILES FROM A LIST'S ARCHIVES

Many list owners keep archives of files associated with a list.  These
may include:
- back issues of the list
- help files, user profiles, and other documents associated with the list
- daily, monthly, or yearly archives for the list

To find out if a list has any files associated with it, use the "index"
command:

	index demo-list

If you see files in which you're interested, you may retrieve them by
using the "get" command and specifying the list name and archive filename.
For instance, to retrieve the files called "profile.form" (presumably a
form to fill out with your profile) and "demo-list.9611" (presumably the
messages posted to the list in November 1996), you would put the lines

	get demo-list profile.form
	get demo-list demo-list.9611

in your mail to $whoami.

VII.	GETTING MORE HELP

To contact a human site manager, send mail to $whoami_owner.
To contact the owner of a specific list, send mail to that list's
approval address, which is formed by adding "-approval" to the user-name
portion of the list's address.  For instance, to contact the list owner
for demo-list\@$whereami, you would send mail to demo-list-approval\@$whereami.

To get another copy of this help message, send mail to $whoami
with a line saying

	help

in the message body.

VIII.	COMMAND SUMMARY FOR ADVANCED USERS

In the description below items contained in []'s are optional. When
providing the item, do not include the []'s around it.  Items in angle
brackets, such as <address>, are meta-symbols that should be replaced
by appropriate text without the angle brackets.

It understands the following commands:

    subscribe $list4help [<address>]
	Subscribe yourself (or <address> if specified) to the named <list>.
	
    unsubscribe $list4help [<address>]
	Unsubscribe yourself (or <address> if specified) from the named <list>.
	"unsubscribe *" will remove you (or <address>) from all lists.  This
	_may not_ work if you have subscribed using multiple addresses.

    get $list4help <filename>
        Get a file related to <list>.

    index $list4help
        Return an index of files you can "get" for <list>.

    which [<address>]
	Find out which lists you (or <address> if specified) are on.

    who $list4help
	Find out who is on the named <list>.

    info $list4help
	Retrieve the general introductory information for the named <list>.

    intro $list4help
	Retrieve the introductory message sent to new users.  Non-subscribers
	may not be able to retrieve this.

    lists
	Show the lists served by this Majordomo server.

    help
	Retrieve this message.

    end
	Stop processing commands (useful if your mailer adds a signature).

Commands should be sent in the body of an email message to
"$whoami"$listrequest Multiple commands can be processed provided
each occurs on a separate line.

Commands in the "Subject:" line are NOT processed.

If you have any questions or problems, please contact
"$whoami_owner".

EOM
#'
    print STDERR "$0:  do_help(): finished writing help text, now logging.\n" if $DEBUG;

    &log("help");

    print STDERR "$0:  do_help(): done\n" if $DEBUG; 
}

sub send_confirm {
    local($cmd) = shift;
    local($list) = &valid_list($listdir, shift);
    local($subscriber) = @_;
    local($cookie) = &gen_cookie($cmd, $list, $subscriber);
	local(*AUTH);

	&sendmail(AUTH, $subscriber, "Confirmation for $cmd $list");

	print AUTH <<"EOM";
Someone (possibly you) has requested that your email address be added
to or deleted from the mailing list "$list\@$whereami".

If you really want this action to be taken, please send the following
commands (exactly as shown) back to "$whoami":

	auth $cookie $cmd $list $subscriber

If you do not want this action to be taken, simply ignore this message
and the request will be disregarded.

If your mailer will not allow you to send the entire command as a single
line, you may split it using backslashes, like so:

        auth $cookie $cmd $list \\
        $subscriber

If you have any questions about the policy of the list owner, please
contact "$list-approval\@$whereami".

Thanks!

$whoami
EOM
	close(AUTH);

    print REPLY <<"EOM";
**** Your request to $whoami:
**** 
**** 	$cmd $list $subscriber
**** 
**** must be authenticated.  To accomplish this, another request must be
**** sent in with an authorization key, which has been sent to:
**** 	$subscriber
**** 
**** If the message is not received, there is generally a problem with
**** the address.  Before reporting this as a problem, please note the
**** following:
****
**** You only need to give an address to the subscribe command if you want
**** to receive list mail at a different address from where you sent the
**** command.  Otherwise you can simply omit it.
****
**** If you do give an address to the subscribe command, it must be a legal
**** address.  It should not consist solely of your name.  The address must
**** point to a machine that is reachable from the list server.
****
**** If you have any questions about the policy of the list owner, please
**** contact "$list-approval\@$whereami".
**** 
**** Thanks!
**** 
**** $whoami
EOM
    &log("send_confirm $cmd $list $subscriber");
}



# Send a request for subscribe or unsubscribe approval to a list owner 
# Usage: &request_approval($cmd, $list, @subscriber)
sub request_approval {
    # Get the arguments
    local($cmd) = shift;
    local($list) = &valid_list($listdir, shift);
    local($subscriber) = @_;
    local(*APPROVE);

    # open a sendmail process for the approval request
    &sendmail(APPROVE, "$list-approval\@$whereami", "APPROVE $list");

    # Generate the approval request
    print APPROVE <<"EOM";
$reply_to requests that you approve the following:

	$cmd $list $subscriber

If you approve, please send a message such as the following back to
$whoami (with the appropriate PASSWORD filled in, of course):

 	approve PASSWORD \\
 	$cmd $list \\
 	$subscriber
  
[The above is broken into multiple lines to avoid mail reader linewrap
problems. Commands can be on one line, or multi-line with '\\' escapes.]

If you disapprove, do nothing.


Thanks!

$whoami
EOM
    # close (and thereby send) the approval request
    close(APPROVE);

    # tell the requestor that their request has been forwarded for approval.
    print REPLY <<"EOM";
Your request to $whoami:

	$cmd $list $subscriber

has been forwarded to the owner of the "$list" list for approval. 
This could be for any of several reasons:

    You might have asked to subscribe to a "closed" list, where all new
	additions must be approved by the list owner. 

    You might have asked to subscribe or unsubscribe an address other than
	the one that appears in the headers of your mail message.

When the list owner approves your request, you will be notified.

If you have any questions about the policy of the list owner, please
contact "$list-approval\@$whereami".


Thanks!

$whoami
EOM
    
    &log("request $cmd $list $subscriber");
}

# We are done processing the request; append help if needed, send the reply
# to the requestor, clean up, and exit

sub done {
    # append help, if needed.
    if ($count == 0) {
	print REPLY "**** No valid commands found.\n";
	print REPLY "**** Commands must be in message BODY, not in HEADER.\n\n";
    }
    if ($needs_help || ($count == 0)) {
	print REPLY "**** Help for $whoami:\n\n";
	&do_help();
    }

    # close (and thereby send) the reply
    close(REPLY);

    # good bye!
    exit(0);
}

# Welcome a new subscriber to the list, and tell the list owner of his/her
# existance.
sub welcome {
    local($list) = shift;
    local($subscriber) = join(" ", @_);

	# welcome/intro message controlled by 'welcome=yes/no'
	if ( &cf_ck_bool($list,"welcome")) {

    # Set up the sendmail process to welcome the new subscriber
    &set_mail_sender($config_opts{$list,"sender"} . "\@" . $whereami);
    &sendmail(MSG, $subscriber, "Welcome to $list");
    &set_mail_sender($whoami_owner);

    print MSG "Welcome to the $list mailing list!\n\n";

     print MSG "Please save this message for future reference.  Thank you.\n";

    if ( $majordomo_request ) {
	print MSG <<"EOM";

If you ever want to remove yourself from this mailing list,
send the following command in email to
\<${clean_list}-request\@$whereami\>:

    unsubscribe

Or you can send mail to \<$whoami\> with the following
EOM
    
} else {
print MSG <<"EOM";

If you ever want to remove yourself from this mailing list,
you can send mail to \<$whoami\> with the following
EOM
}

print MSG <<"EOM";
command in the body of your email message:

    unsubscribe $list

or from another account, besides $subscriber:

    unsubscribe $list $subscriber

EOM
print MSG <<"EOM";
If you ever need to get in contact with the owner of the list,
(if you have trouble unsubscribing, or have questions about the
list itself) send email to \<owner-$clean_list\@$whereami\> .
This is the general rule for most mailing lists when you need
to contact a human.

EOM
    
    # send them the info for the list, if it's available
    # the <list>.intro file has information for subscribers only
    if (&lopen(INFO, "", "$listdir/$list.intro")) {
	while (<INFO>) {
 	    print MSG $_;
 	}
 	&lclose(INFO);
    } elsif (&lopen(INFO, "", "$listdir/$list.info")) {
 	print MSG <<"EOM";
 Here's the general information for the list you've subscribed to,
 in case you don't already have it:

EOM
#';
     while (<INFO>) {
	    print MSG $_;
	}
	&lclose(INFO);
    } else {
	print MSG "#### No info available for $list.\n";
    }

    # close (and thereby send) the welcome message to the subscriber
    close(MSG);

	}

    # tell the list owner of the new subscriber (optional: announcements=yes/no)
	if ( &cf_ck_bool($list,"announcements")) {
    &sendmail(NOTICE, "$list-approval\@$whereami", "SUBSCRIBE $list $subscriber");
    print NOTICE "$subscriber has been added to $list.\n";
    print NOTICE "No action is required on your part.\n";
    close(NOTICE);
	}
}

# complain about a user screwup, and note that the user needs help appended
# to the reply
sub squawk {
    print REPLY "**** @_\n";
    $needs_help++;
}

# check to see if the subscriber is a LISTSERV-style "real name", not an
# address.  If it contains white space and no routing characters ([!@%:]),
# then it's probably not an address.  If it's valid, generate the proper
# request for approval; if it's not, bitch to the user.

# if a fourth parameter is added to the check_and_request call, only
# check the subscribe request for a valid address. This allows
# the same routine to be used for checking when handling an auto list.

sub check_and_request {
    local($request,$clean_list, $subscriber, $do_request) = @_;

    # check to see if the subscriber looks like a LISTSERV-style
    # "real name", not an address; if so, send a message to the
    # requestor, and if not, ask the list owner for approval
    local($addr) = &valid_addr($subscriber);
    if ($addr =~ /\s/ && $addr !~ /[!%\@:]/) {
	# yup, looks like a LISTSERV-style request to me.
	&squawk("$request: LISTSERV-style request failed");
	print REPLY <<"EOM";
This looks like a BITNET LISTSERV style '$request' request, because
the part after the list name doesn't look like an email address; it looks
like a person's name.  Majordomo is not LISTSERV.  In a Majordomo '$request'
request, the part after the list name is optional, but if it's there, it
should be an email address, NOT a person's real name.
EOM

    return(0);
    } else {
	return(1) if defined($do_request);
	&request_approval($request, $clean_list, $subscriber);
    }
}

sub gen_cookie {
    local($combined) = join('/', $cookie_seed ? $cookie_seed : $homedir, @_);
    local($cookie) = 0;
    local($i, $carry);

    # Because of backslashing and all of the splitting on whitespace and
    # joining that goes on, we need to ignore whitespace.
    $combined =~ s/\s//g;
    
    for ($i = 0; $i < length($combined); $i++) {
	$cookie ^= ord(substr($combined, $i));
	$carry = ($cookie >> 28) & 0xf;
	$cookie <<= 4;
	$cookie |= $carry;
    }
    return (sprintf("%08x", $cookie));
}


# Extracts the list name from the argument list to the do_* functions
# or uses the default list name, depending on invocation options and
# available arguments. Returns the raw list name, the validated list
# name, and the remaining argument list.

sub get_listname {
    local($request, $required, @args) = @_;
    local($raw_list, $clean_list);

    if (defined($deflist)) {		# -l option specified
	if (scalar(@args) <= $required) { # minimal arguments, use default list
	    if ( !( ($raw_list = $deflist)
	    && ($clean_list = &valid_list($listdir, $raw_list)) ) ) {
		$raw_list = shift(@args) || &squawk("$request: which list?");
		$clean_list = &valid_list($listdir, $raw_list);
	    }
	}
	elsif ( !( ($raw_list = shift(@args))
	&& ($clean_list = &valid_list($listdir, $raw_list)) ) ) {
	    unshift(@args, $raw_list);		# Not a list name, put it back.
	    $raw_list = $deflist || &squawk("$request: which list?");
	    $clean_list = &valid_list($listdir, $raw_list);
	}
    }

    else {
	$raw_list   = shift(@args);
	$clean_list = &valid_list($listdir, $raw_list);
    }

    return ($raw_list, $clean_list, @args);
}
