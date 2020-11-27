#!/usr/bin/perl
# $Id: pmake,v 1.17 2020-11-23 12:24:29-08 - - $

$0 =~ s|.*/||;
use Getopt::Std;
use Data::Dumper;
use strict;
use warnings;

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
my %RULES;

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
         my @prereqs = @GRAPH{$target}{PREREQS};
         $MAIN_TARGET = $prereqs[0] unless $MAIN_DEP;
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

# helper function for exec_command
# returns the string to for the actual command
sub parse_cmd($) {
  my $ret_str = @_;
  $ret_str =~ s/\$@/$MAIN_TARGET;/g;
  $ret_str =~ s/\$\^/$MAIN_DEP/g;
  # check for MACROS
  while ($ret_str =~ /\$\((.*?)\)/g) {
     $ret_str =~ s/\$\((.*?)\)/$MACROS{$1}/;
     say "curr item: $1"
  }
  print "The command about to be executed: "
  print $ret_str;
  return ret_str;
}

# processes and executes a command
sub exec_command($) {
  # @ contains the single command and its args
  my ($cmd_str) = @_;
  say "cmd_str: $cmd_str";
  my $cmd_ret_val;
  my $actual_cmd;
  my $special_cmd;

  # substitute all macros
  $actual_cmd = parse_cmd($cmd_str);

  if ($actual_cmd =~ /^@(.*)/) {
    # exec the cmd
    $special_cmd = $1;
    say "special_cmd: $1";
    $cmd_ret_val = system($special_cmd);
  }
  elsif ($actual_cmd =~ /^-(.*)/) {
    $special_cmd = $1;
    say "special_cmd: $1";
    $cmd_ret_val = system($special_cmd);
    $MINUS_FLAG = 1;
    # set a global flag or something
    return;
  }
  else {
    $cmd_ret_val = system($actual_cmd);
    print "the echoed command: ";
    system("echo $actual_cmd");
  }

  unless ($cmd_ret_val == 0) {
    # print the string error to stderr
    say "An error has occured :("
  }

  $TERM_SIGNAL = $? & 0x7F;
  $CORE_DUMPED = $? & 0x80;
  $EXIT_STATUS = ($? >> 8) & 0xFF;
  say "term_signal is $TERM_SIGNAL";
  say "core_dumped is $CORE_DUMPED";
  say "exit_status is $EXIT_STATUS";

  # if /^@/ then don't echo
  # else if /^-/ then make sure pmake doesn't exit
  # else echo the command to stdout system("echo ...")
  return;
}

# return value: 0 if nothing needs to be done
# 1 if target needs to be made (command should execute)
sub check_file_date() {
#gonna need the target and one of its pre-requisites
  my ($target_file, $dep_file) = @_;
  my $target_mod_time = mtime($target_file);
  my $dep_mod_time = mtime($dep_file);
  if ($target_mod_time < $dep_mod_time) {
    return 1;
  }
  else {
    return 0;
  }
}

# try to get to the deepest target
sub make_target() {
  # check the target's dependencies to see if they are also a target
  my ($target) = @_;
  my @curr_deps;
  @curr_deps = @GRAPH{$target}{PREREQS};
  foreach (@curr_deps) {
    if ($GRAPH{$_}) {
      make_target($_);
    }
  }
  $MAIN_TARGET = $target;
  $MAIN_DEP = $curr_deps[0];
  # once there are no dependencies that are apart of the GRAPH, then start comparing modify times
  if (scalar(@curr_deps)) {
    # then the target does have deps and their times must be compared
    for my $curr_dep_item(@curr_deps) {
      # check the time - if time is greater, then exec commands and return
      last if (check_file_date($target, $curr_dep_item)) {
        # then dep is older and the commands need to be executed
        foreach(@GRAPH{$target}{COMMANDS}) {
          # call exec_command
          print "command ***$_*** is about to be executed\n";
          exec_command($_);
        }
      }
    }
  }
  else {
    # if the target has no deps, then just execute the commands
    foreach(@GRAPH{$target}{COMMANDS}) {
      exec_command($_);
    }
  }
  # if the modify times of the deps are greater than the curr target, then exec the commands
}

sub exec_Makefile() {
  # an attempt to execute the loaded Makefile

  # go through the entire hash of targets and make them recursively
}

scan_cmdline;
load_Makefile;

print "%MACROS: ", Data::Dumper->Dump ([\%MACROS]) if $OPTIONS{'d'};
print "%GRAPH: ", Data::Dumper->Dump ([\%GRAPH]) if $OPTIONS{'d'};
dump_macros if $OPTIONS{'m'};
dump_graph if $OPTIONS{'g'};
