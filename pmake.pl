#!/usr/bin/perl
# $Id: pmake,v 1.17 2020-11-23 12:24:29-08 - - $

$0 =~ s|.*/||;
use Getopt::Std;
use Data::Dumper;
use strict;
use warnings;
use feature qw(say);

$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 1;

my $STATUS = 0;
END { exit $STATUS; }
sub note (@) { print STDERR @_; };
$SIG{'__WARN__'} = sub { note @_; $STATUS = 1; };
$SIG{'__DIE__'} = sub { warn @_; $STATUS = 1; exit; };

# sigtoperl: x86_64 Linux unix1.lt.ucsc.edu
# sigtoperl: Sun Nov 22 17:33:55 2020
my %strsignal = (
    0 => "Unknown signal 0",
    1 => "Hangup",
    2 => "Interrupt",
    3 => "Quit",
    4 => "Illegal instruction",
    5 => "Trace/breakpoint trap",
    6 => "Aborted",
    7 => "Bus error",
    8 => "Floating point exception",
    9 => "Killed",
   10 => "User defined signal 1",
   11 => "Segmentation fault",
   12 => "User defined signal 2",
   13 => "Broken pipe",
   14 => "Alarm clock",
   15 => "Terminated",
   16 => "Stack fault",
   17 => "Child exited",
   18 => "Continued",
   19 => "Stopped (signal)",
   20 => "Stopped",
   21 => "Stopped (tty input)",
   22 => "Stopped (tty output)",
   23 => "Urgent I/O condition",
   24 => "CPU time limit exceeded",
   25 => "File size limit exceeded",
   26 => "Virtual timer expired",
   27 => "Profiling timer expired",
   28 => "Window changed",
   29 => "I/O possible",
   30 => "Power failure",
   31 => "Bad system call",
);

sub status_string ($) {
   my ($status) = @_;
   return undef unless $status;
   $status &= 0xFFFF;
   return sprintf "Error %d", $status >> 8 if ($status & 0xFF) == 0;
   my $message = $strsignal{$status & 0x7F} || "Invalid Signal Number";
   $message .= " (core dumped)" if $status & 0x80;
   return $message;
}

# Global Scalars
my $MINUS_FLAG = 0;
my $MAIN_TARGET;
my $MAIN_DEP;
my $Makefile = "Makefile";
my $TERM_SIGNAL;
my $CORE_DUMPED;
my $EXIT_STATUS;

# Global Hashes
my %OPTIONS;
my %GRAPH;
my %MACROS;
my %MADE_TARGETS;

sub usage() { die "Usage: $0 [-d] [target]\n" }
sub stop($) { die "$Makefile:@_. Stop.\n" }

sub scan_cmdline() {
   getopts "dgm", \%OPTIONS;
   usage unless @ARGV <= 1;
   $MAIN_TARGET = $ARGV[0];
}

sub dump_macros() {
   for my $macro (sort keys %MACROS) {
      print "MACRO{$macro} = [$MACROS{$macro}]\n";
   }
}

sub dump_graph() {
   print "MAIN_TARGET = [$MAIN_TARGET]\n";
   for my $target (sort keys %GRAPH) {
      my $prereqs = $GRAPH{$target}{PREREQS};
      print "$GRAPH{$target}{LINE} $target : [@$prereqs]\n";
      for my $command (@{$GRAPH{$target}{COMMANDS}}) {
         print "...[$command]\n";
      }
   }
}

sub load_Makefile() {
   open my $mkfile, "<$Makefile" or die "$0: $Makefile: $!";
   my $target;
   while (defined (my $line = <$mkfile>)) {
      next if $line =~ m/^\s*(#|$)/;
      if (!$target && $line =~ m/^\s*(\S+)\s*=\s*(.*?)\s*$/) {  # a macro is encountered
         $MACROS{$1} = $2;
      }elsif ($line =~ m/^(\S+)\s*:\s*(.*)/) {                  # target and list of dependencies is encountered
         $target = $1;
         $GRAPH{$target}{PREREQS} = [split ' ', $2];
         $GRAPH{$target}{LINE} = $.;
         $MAIN_TARGET = $target unless $MAIN_TARGET;
         $MAIN_DEP = $GRAPH{$target}{PREREQS}[0] unless $MAIN_DEP;
      }elsif ($line =~ m/^\t(.*)/) {                            # a command is encountered
         if (defined $target) {
            push @{$GRAPH{$target}{COMMANDS}}, $1;
         }else {
            stop "$.: Command before first target";
         }
      }else {
         stop "$.: Missing separator";
      }
   }
   close $mkfile;
}

sub mtime ($) {
   my ($filename) = @_;
   my @stat = stat $filename;
   return @stat ? $stat[9] : undef;
}

# helper function for exec_command
# returns the string to for the actual command
sub parse_cmd($) {
  my ($ret_str) = @_;
  $ret_str =~ s/\$@/$MAIN_TARGET;/g;
  $ret_str =~ s/\$</$MAIN_DEP/g;
  # check for MACROS
  while ($ret_str =~ /\$\((.*?)\)/g) {
     $ret_str =~ s/\$\((.*?)\)/$MACROS{$1}/;
     say "curr item: $1"
  }
  return $ret_str;
}

sub error_handle() {
  $TERM_SIGNAL = $? & 0x7F;
  $CORE_DUMPED = $? & 0x80;
  $EXIT_STATUS = ($? >> 8) & 0xFF;
  say "term_signal is $TERM_SIGNAL";
  say "core_dumped is $CORE_DUMPED";
  say "exit_status is $EXIT_STATUS";
  print "exit status: $strsignal{$EXIT_STATUS}\n";
  die "An error has occured, pmake has been aborted\n";
}

# processes and executes a command
sub exec_command($) {
  # @ contains the single command and its args
  my ($cmd_str) = @_;
  #say "cmd_str: $cmd_str";
  my $cmd_ret_val;
  my $actual_cmd;
  my $special_cmd;

  # substitute all macros
  $actual_cmd = parse_cmd($cmd_str);

  if ($actual_cmd =~ /^@(.*)/) {
    $special_cmd = $1;
    system($special_cmd) == 0 or error_handle;
  }
  elsif ($actual_cmd =~ /^-(.*)/) {
    $special_cmd = $1;
    system($special_cmd);
    $MINUS_FLAG = 1;
    return;
  }
  else {
    system($actual_cmd) == 0 or error_handle;
    system("echo $actual_cmd");
  }

  return;
}

# return value: 0 if nothing needs to be done
# 1 if target needs to be made (command should execute)
sub check_file_date() {
#gonna need the target and one of its pre-requisites
  my ($target_file, $dep_file) = @_;
  my $target_mod_time = mtime($target_file);
  my $dep_mod_time = mtime($dep_file);
  # unless ($target_mod_time && $dep_mod_time) {
  #   die "Error: file $target_file or $dep_file missing\n";
  # }
  if ($target_mod_time < $dep_mod_time) {
    return 1;
  }
  else {
    return 0;
  }
}

# try to get to the deepest target
sub make_target {
  my ($target) = @_;
  my $curr_deps;
  my $curr_commands;
  $curr_deps = $GRAPH{$target}{PREREQS};

  # check the target's dependencies to see if they are also a target
  foreach (@{$curr_deps}) {
    if ($GRAPH{$_}) {
      make_target($_);
    }
  }

  # set the main target to the current target
  # and the first dependency on the list to the main dependency (if they exist)
  $MAIN_TARGET = $target;
  if (scalar(@{$curr_deps})) {
    $MAIN_DEP = ${$curr_deps}[0];
  }

  $curr_commands = $GRAPH{$target}{COMMANDS};

  # once we have gotten the deepest target on the GRAPH, then start comparing modify times
  if (scalar(@{$curr_deps})) {
    # then the target does have deps and their modify times must be compared
      for my $curr_dep_item(@{$curr_deps}) {
        # check the time - if the dep's modify time is greater, then exec commands and return
        if ( (!(-e $target)) ) {
          $MADE_TARGETS{$target}{"is_Made"} = 1;
          for my $element(@{$curr_commands}) {
            # the dep is newer - call exec_command
            exec_command($element);
          }
          last;
        }
        elsif ( (&check_file_date($target, $curr_dep_item)) ) {
          $MADE_TARGETS{$target}{"is_Made"} = 1;
          for my $element(@{$curr_commands}) {
            # the dep is newer - call exec_command
            exec_command($element);
          }
          last;
        }
      }
  }
  else {
    # if the target has no deps, then just execute the commands
    for my $element (@{$curr_commands}) {
      exec_command($element);
    }
  }

  return;
}

scan_cmdline;
load_Makefile;
# Call makefile on MAIN TARGET first
make_target($MAIN_TARGET);

print "%MACROS: ", Data::Dumper->Dump ([\%MACROS]) if $OPTIONS{'d'};
print "%GRAPH: ", Data::Dumper->Dump ([\%GRAPH]) if $OPTIONS{'d'};
dump_macros if $OPTIONS{'m'};
dump_graph if $OPTIONS{'g'};
