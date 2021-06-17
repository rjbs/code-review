package RJBS::CodeReview;

use v5.30.0;
use warnings;
use utf8;

use Moo;
with 'CliM8::App';

use experimental 'signatures';

sub name { 'code-review' }

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
        queue => RJBS::CodeReview::ReviewQueue->new({
          items => [ map {; +{ name => $_ } } $self->projects->@* ],
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
    return { name => $key };
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

  sub queue_item_noun { 'project' }

  __PACKAGE__->add_queue_commands;

  has queue => (is => 'ro', required => 1);

  sub maybe_describe_item ($self, $item, $needle) {
    return undef if defined $needle and index(fc $item->{name}, $needle) == -1;

    return { brief => $item->{name} };
  }

  sub assert_queue_not_empty ($self) {
    return if $self->queue->count;
    errsay("You can't do this without a project queue.");
    no warnings 'exiting';
    cmdnext;
  }

  has last_interacted_project_name => (is => 'rw');

  sub _get_notes ($self, $project) {
    return $project->{notes} //= do {
      [ main::notes_for($project->{name}) ];
    }
  }

  sub interact ($self) {
    my $project = $self->queue->get_current;

    if (($self->last_interacted_project_name//'') ne $project->{name}) {
      say q{};
      say "=== $project->{name} ==========";
      printf "    %s\n", $_ for $self->_get_notes($project)->@*;
      $self->last_interacted_project_name($project ? $project->{name} : undef);
    }

    say q{};

    my $prompt;
    if ($project) {
      $prompt = colored_prompt(
        'prompt',
        "$project->{name} > ",
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

  command 'q.uit' => (
    aliases => [ 'exit' ],
    help    => {
      summary => 'call it a day',
      text    => "Declare you're done and quit.",
    },
    sub { CliM8::LoopControl::Empty->new->throw },
  );

  # TODO: [S]hell out, [O]pen in browser, [L]ook again, [Q]uit
  command 'r.eviewed' => (
    help => {
      summary => 'mark this project as reviewed',
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;

      main::mark_reviewed($project->{name});

      okaysay("Cool, $project->{name} has been reviewed!");
      cmdnext;
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
      say "=== $project->{name} ==========";
      printf "    %s\n", $_ for $self->_get_notes($project)->@*;

      cmdnext;
    }
  );

  command 'o.pen' => (
    help  => {
      summary => "open the project's GitHub page in a browser",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;

      my $repo = qq{https://github.com/rjbs/$project->{name}/}; # Naive.
      system("open", $repo);
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
      my $name    = $project->{name};

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
