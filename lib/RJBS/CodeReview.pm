package RJBS::CodeReview;

use v5.30.0;
use warnings;
use utf8;

use Moo;
with 'CliM8::App';

use experimental 'signatures';

use JSON::MaybeXS ();
use List::AllUtils qw(uniq);

sub name { 'code-review' }

has json => (
  is => 'ro',
  init_arg => undef,
  default  => sub {
    JSON::MaybeXS->new->pretty->canonical;
  },
);

sub decode_json_res ($self, $res) {
  return $self->json->decode( $res->decoded_content(charset => undef) );
}

has github_id => (is => 'ro');

has _state => (
  is => 'ro',
  lazy    => 1,
  default => sub {
    YAML::XS::LoadFile('code-review.yaml');
  },
);

sub _mark_reviewed {
  my ($self, $name, $message) = @_;
  $self->_state->{$name}{'last-review'} = DateTime->now(time_zone => 'local')
                                           ->format_cldr('yyyy-MM-dd');

  $self->_commit_state($name, $message);
}

sub _commit_state {
  my ($self, $project, $message) = @_;

  my $state = $self->_state;

  my %dump = map {; $_ => {
    ($state->{$_}{home}   ? (home => $state->{$_}{home})     : ()),
    ($state->{$_}{review} ? (review => $state->{$_}{review}) : ()),
    ($state->{$_}{'last-review'}
    ? ('last-review' => $state->{$_}{'last-review'})
    : ()),
    ($state->{$_}{'review-every'}
    ? ('review-every' => $state->{$_}{'review-every'})
    : ()),
  } } uniq(@main::projects, keys $state->%*);

  YAML::XS::DumpFile('code-review.yaml', \%dump);

  system(qw(git add code-review.yaml)) and die "git-add failed\n";
  my $msg = $message
          || ($project ? "did review of $project"
                       : "rebuilt code-review state file");

  my $gh_user = $self->github_id;
  open my $mkdn, '>', 'code-review.mkdn' or die "can't open mkdn: $!";

  print {$mkdn} <<END_HEADER;
This file is computer-generated for humans to read.  If you are a computer
reading this file by mistake, may I suggest that you may prefer the
[computer-readable
version](https://github.com/$gh_user/misc/blob/master/code-review.yaml) instead.
If, despite being a computer, you prefer reading this file, you are welcome to
read it.  Be advised, though, that its format may change in the future.

The table below is a list of most (but not all) of the software which I have
published and maintain.  Most of these projects are CPAN distributions.  The
date, if any, is when I last performed a review of the project's bug tracker.
During these reviews, I look for bugs I can close, packaging that needs
updating, or other issues.  A review does not necessarily close all the open
issues with a project.

Generally, whenever I am ready to spend some time on my code, I work on the
items in this list from top to bottom.  Once I've worked on an item, it moves
to the bottom of the list.

You can read [the program that generates this
file](https://github.com/$gh_user/misc/blob/master/code-review) if you like.

| PROJECT NAME                            | LAST REVIEW
| --------------------------------------- | -------------
END_HEADER

  printf {$mkdn} "| %-40s| %s\n", $_, $state->{$_}{'last-review'} // '-'
    for sort {
      ($state->{$a}{'last-review'} // '0') cmp ($state->{$b}{'last-review'} // 0)
      ||
      fc $a cmp fc $b } @main::projects;

  close $mkdn or die "error closing mkdn: $!";

  system(qw(git add), <code-review.*>) and die "git-add failed\n";

  my $lines = `git diff --staged`;
  chomp $lines;
  unless (length $lines) {
    say "No changes to commit";
    return;
  }

  system(qw(git commit -m), $msg)  and die "git-commit failed\n";
}

my %ACTIVITY = (
  boot    => 'RJBS::CodeReview::Activity::Boot',
  review  => 'RJBS::CodeReview::Activity::Review',
);

sub activity ($self, $name, $arg = {}) {
  die "unknown activity $name" unless my $class = $ACTIVITY{ $name };

  return $class->new({
    %$arg,
    app => $self,
  });
}

package RJBS::CodeReview::Activity::Boot {
  use Moo;
  with 'CliM8::Activity';

  use experimental 'signatures';

  has projects => (is => 'ro');

  sub interact ($self) {
    my $activity = $self->app->activity(
      'review',
      {
        begin_with_autoreview => 1,
        queue => RJBS::CodeReview::ReviewQueue->new({
          items => [ map {; +{ id => $_ } } $self->projects->@* ],
          query => undef, # XXX This is obviously stupid. -- rjbs, 2021-06-17
        }),
      },
    );

    CliM8::LoopControl::Swap->new({ activity => $activity })->throw;
  }

  no Moo;
}

package RJBS::CodeReview::ReviewQueue {
  use Moo;
  with 'CliM8::Role::Queue';

  use experimental 'signatures';

  sub inflate ($self, $key) {
    return { id => $key };
  }

  no Moose;
}

package RJBS::CodeReview::Activity::Review {
  use Moo;
  sub queue;
  with 'CliM8::Activity',
       'CliM8::Role::Readline',
       'CliM8::Role::HasQueue';

  use experimental 'signatures';

  use CliM8::Commando -setup => {
    help_sections => [
      { key => '',          title => 'The Basics' },
    ]
  };

  use CliM8::Commando::Completionist -all;
  use CliM8::Debug;
  use CliM8::Util qw(
    cmderr
    cmdmissing
    cmdnext
    cmdlast

    matesay
    errsay
    okaysay

    colored
    colored_prompt
  );

  around build_readline => sub ($orig, $self) {
    my $term = $self->$orig;

    my $completion_handler = $self->commando->_build_completion_function($self);

    $term->Attribs->{attempted_completion_function} = $completion_handler;

    $term->Attribs->{completer_word_break_characters} = qq[ \t\n];
    $term->Attribs->{completion_entry_function} = sub { undef };

    return $term;
  };

  sub _complete_from_array ($self, $array_ref) {
    my @array = @$array_ref;
    $self->readline->Attribs->{completion_entry_function} = sub { shift @array; };
    return undef;
  }

  sub queue_item_noun { 'project' }

  __PACKAGE__->add_queue_commands;

  has _do_autoreview => (
    is => 'rw',
    init_arg => 'begin_with_autoreview',
  );

  has queue => (is => 'ro', required => 1);

  sub maybe_describe_item ($self, $item, $needle) {
    return undef if defined $needle and index(fc $item->{id}, $needle) == -1;

    return { brief => $item->{id} };
  }

  sub assert_queue_not_empty ($self) {
    return if $self->queue->count;
    errsay("You can't do this without a project queue.");
    no warnings 'exiting';
    cmdnext;
  }

  has last_interacted_project_id => (is => 'rw');

  sub _get_notes ($self, $project) {
    return $project->{notes} //= do {
      [ main::notes_for($project->{id}) ];
    }
  }

  sub interact ($self) {
    my $project = $self->queue->get_current;

    if (($self->last_interacted_project_id//'') ne $project->{id}) {
      say q{};
      say "=== $project->{id} ==========";
      printf "    %s\n", $_ for $self->_get_notes($project)->@*;
      $self->last_interacted_project_id($project ? $project->{id} : undef);
    }

    if ($self->_do_autoreview) {
      $self->_do_autoreview(0);
      $self->_execute_autoreview;
    }

    say q{};

    my $prompt;
    if ($project) {
      $prompt = colored_prompt(
        'prompt',
        "$project->{id} > ",
      );
    } else {
      $prompt = colored_prompt(['cyan'], 'no project > ');
    }

    my $input = $self->get_input($prompt);

    cmdlast unless defined $input;
    cmdnext unless length $input;

    my ($cmd, $rest) = split /\s+/, $input, 2;
    if (my $command = $self->commando->command_for($cmd)) {
      my $code = $command->{code};
      $self->$code($cmd, $rest);
      cmdnext;
    }

    cmderr("I don't know what you wanted to do!");

    return $self;
  }

  sub _execute_autoreview ($self)  {
    PROJECT: while (1) {
      my $project = $self->queue->get_current;
      my $notes = $self->_get_notes($project);

      if (@$notes) {
        # We hit a project with problems.  Let's stop and work on it.
        cmdnext;
      }

      my $name = $project->{id};
      matesay "$name - No problems!  Great, moving on!";
      $self->app->_mark_reviewed($name, "reviewed $name, no problems");

      last PROJECT unless $self->queue->maybe_next;
    }

    matesay("We got to the end of the queue!  Wow!");
    cmdnext;
  }

  command 'q.uit' => (
    aliases => [ 'exit' ],
    help    => {
      summary => 'call it a day',
      text    => "Declare you're done and quit.",
    },
    sub { CliM8::LoopControl::Empty->new->throw },
  );

  command 'r.eviewed' => (
    help => {
      summary => 'mark this project as reviewed',
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;

      $self->app->_mark_reviewed($project->{id});

      okaysay("Cool, $project->{id} has been reviewed!");

      unless ($self->queue->maybe_next) {
        matesay("Can't go to the next task, because that was the last one!");
        cmdnext;
      }

      $self->_execute_autoreview;
    }
  );

  command 'problems' => (
    aliases => [ 't' ], # to match LP-Mate "t"
    help    => {
      summary => 'print the project summary out again',
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;

      say q{};
      say "=== $project->{id} ==========";
      printf "    %s\n", $_ for $self->_get_notes($project)->@*;

      cmdnext;
    }
  );

  command 'a.uto.review' => (
    help => {
      summary => "move forward until a project with problems",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      $self->_execute_autoreview;
    }
  );

  command 'na' => (
    help => {
      summary => "next item, then start an autoreview",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      unless ($self->queue->maybe_next) {
        matesay("Can't go to the next task, because that was the last one!");
        cmdnext;
      }
      $self->_execute_autoreview;
    }
  );

  command 're.fresh' => (
    help => {
      summary => "look at the current project to re-check problems",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      $self->queue->invalidate_current;
      $self->queue->get_current;
      okaysay "Task refetched!";
      cmdnext;
    }
  );

  command 'github' => (
    aliases => [ 'gh' ],
    help    => {
      summary => "open the project's GitHub page in a browser",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $name = $self->queue->get_current->{id};

      my $link = qq{https://github.com/rjbs/$name/}; # Naive.
      system("open", $link);
      okaysay "Opened in your browser: $link";
      cmdnext;
    },
  );

  command 'rt.cpan' => (
    help    => {
      summary => "open the project's rt.cpan.org queue in a browser",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $name = $self->queue->get_current->{id};

      my $link = qq{https://rt.cpan.org/Dist/Display.html?Name=$name};
      system("open", $link);
      okaysay "Opened in your browser: $link";
      cmdnext;
    },
  );

  command 's.hell' => (
    help  => {
      summary => "open a tmux window for this project",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;
      my $name    = $project->{id};

      my $directory = "$ENV{HOME}/code/hub/$name";

      unless (-d $directory) {
        print "Sorry, $directory doesn't exist.\n";
      }

      if ($ENV{TMUX}) {
        system('tmux', 'new-window', '-c', $directory, '-n', $name);
      } else {
        print "Non-tmux shell-out not implemented.  Meh.\n";
      }

      cmdnext;
    },
  );

  no Moo;
}

no Moo;
1;
