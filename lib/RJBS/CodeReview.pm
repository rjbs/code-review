package RJBS::CodeReview;

use v5.30.0;
use warnings;
use utf8;

use Moo;
with 'Yakker::App';

use experimental 'signatures';

use JSON::MaybeXS ();
use List::AllUtils qw(uniq);

sub name { 'code-review' }

has http_agent => (is => 'ro', required => 1);

has json => (
  is => 'ro',
  init_arg => undef,
  default  => sub {
    JSON::MaybeXS->new->pretty->canonical;
  },
);

has dist => (
  is => 'rw',
  default => sub {  {}  },
);

has projects => (
  is => 'bare',
  reader => '_projects',
  writer => 'set_projects',
);

sub projects ($self) { $self->_projects->@* }

has filtered_projects => (
  is => 'bare',
  reader => '_filtered_projects',
  writer => 'set_filtered_projects',
);

sub filtered_projects ($self) { $self->_filtered_projects->@* }

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
  my ($self, $name) = @_;
  $self->_state->{$name}{'last-review'} = DateTime->now(time_zone => 'local')
                                           ->format_cldr('yyyy-MM-dd');

  $self->_commit_state($name);
}

sub _never_review {
  my ($self, $name) = @_;
  $self->_state->{$name}{review} = 'never';

  $self->_commit_state($name, "marked $name as never-review");
}

my sub card {
  my ($text, $arg) = @_;

  my @top_hunks = $arg->{top}->@*;
  my @bot_hunks = $arg->{bottom}->@*;

  state $top = Yakker::Util::colored('dim', "┌──┤");
  state $bar = Yakker::Util::colored('dim', "│");
  state $bot = Yakker::Util::colored('dim', "└──┤");

  my $str = q{};

  $str .= $top;
  $str .= " $_ $bar" for @top_hunks;
  $str .= "\n";

  my @lines = split /\n/, $text, -1;
  $str .= "$bar $_\n" for @lines;

  $str .= $bot;
  $str .= " $_ $bar" for @bot_hunks;
  $str .= "\n";

  return $str;
}

# { sha => $SHA, reviewed => [ dist1, dist2, ... ] }
has _my_last_commit => (
  is => 'rw',
);

sub _commit_state {
  my ($self, $project, $message, $never_amend) = @_;

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
  } } uniq($self->projects, keys $state->%*);

  YAML::XS::DumpFile('code-review.yaml', \%dump);

  system(qw(git add code-review.yaml)) and die "git-add failed\n";

  my $gh_user = $self->github_id;
  open my $mkdn, '>', 'code-review.mkdn' or die "can't open mkdn: $!";

  print {$mkdn} <<END_HEADER;
This file is computer-generated for humans to read.  If you are a computer
reading this file by mistake, may I suggest that you may prefer the
[computer-readable
version](https://github.com/$gh_user/code-review/blob/main/code-review.yaml) instead.
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
file](https://github.com/$gh_user/code-review/blob/main/code-review) if you like.

| PROJECT NAME                            | LAST REVIEW
| --------------------------------------- | -------------
END_HEADER

  for my $project (
    sort {
      ($state->{$a}{'last-review'} // '0') cmp ($state->{$b}{'last-review'} // 0)
      ||
      fc $a cmp fc $b
    } $self->projects
  ) {
    next if ($state->{$project}{review} // '') eq 'never';

    printf {$mkdn} "| %-40s| %s\n",
      $project,
      $state->{$project}{'last-review'} // '-';
  }

  close $mkdn or die "error closing mkdn: $!";

  system(qw(git add), <code-review.*>) and die "git-add failed\n";

  my $lines = `git diff --staged`;
  chomp $lines;
  unless (length $lines) {
    say "No changes to commit";
    return;
  }

  my $do_amend;
  my $last = $self->_my_last_commit || { sha => '', dists => [] };

  if ($last->{sha}) {
    my $head_sha = `git rev-parse HEAD`;
    chomp $head_sha;

    if ($head_sha eq $last->{sha} && ! $never_amend) {
      $do_amend = 1;
    } else {
      $last = { sha => '', dists => [] };
    }
  }

  if ($project) {
    push $last->{dists}->@*, $project;
  }

  my $now = DateTime->now(time_zone => 'local')->format_cldr('yyyy-MM-dd');

  my $msg;
  my @dists = $last->{dists}->@*;
  if (@dists > 1) {
    $msg = "performed code review ($now)\n\n";
    $msg .= "* $_\n" for @dists;
  } elsif (@dists == 1) {
    $msg = "performed code review ($now, $dists[0])";
  } else {
    $msg = "rebuilt code-review state file";
  }

  $msg = $message if $message;

  system(qw(git commit), ($do_amend ? '--amend' : ()), '-m', $msg)
    and die "git-commit failed\n";

  my $sha = `git rev-parse HEAD`;
  chomp $sha;
  $last->{sha} = $sha;
  $self->_my_last_commit($last);

  return;
}

sub activity_class ($self, $name) {
  state %ACTIVITY = (
    boot    => 'RJBS::CodeReview::Activity::Boot',
    review  => 'RJBS::CodeReview::Activity::Review',
  );

  return $ACTIVITY{$name};
}

package RJBS::CodeReview::Activity::Boot {
  use Moo;
  with 'Yakker::Role::Activity';

  use experimental 'signatures';

  sub interact ($self) {
    my $activity = $self->app->activity(
      'review',
      {
        begin_with_autoreview => 1,
        queue => RJBS::CodeReview::ReviewQueue->new({
          items => [ map {; +{ id => $_ } } $self->app->filtered_projects ],
          query => undef, # XXX This is obviously stupid. -- rjbs, 2021-06-17
        }),
      },
    );

    Yakker::LoopControl::Swap->new({ activity => $activity })->throw;
  }

  no Moo;
}

package RJBS::CodeReview::ReviewQueue {
  use Moo;
  with 'Yakker::Role::Queue';

  use experimental 'signatures';

  sub inflate ($self, $key) {
    return { id => $key };
  }

  no Moose;
}

package RJBS::CodeReview::Activity::Review {
  use Moo;
  sub queue;
  with 'Yakker::Role::Activity::Commando',
       'Yakker::Role::HasQueue';

  use experimental 'signatures';

  use Yakker::Commando -setup => {
    help_sections => [
      { key => '',          title => 'The Basics' },
    ]
  };

  use Yakker::Commando::Completionist -all;
  use Yakker::Debug;
  use Yakker::Util qw(
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
      [ $self->_notes_for_project($project->{id}) ];
    }
  }

  sub _project_card ($self, $project) {
    my $last_review = $self->app->_state->{$project->{id}}{'last-review'}
                   // 'never';

    my @notes = $self->_get_notes($project)->@*;
    my $text  = @notes
              ? (join qq{\n}, @notes)
              : "\N{SPARKLES}  Everything is fine!  \N{SPARKLES}";

    return card("\n$text\n", {
      top     => [ Yakker::Util::colored('header', $project->{id}) ],
      bottom  => [
        "Last review: " .
        # Yakker::Util::colored('header', $last_review)
        Yakker::Util::colored('bold', $last_review)
      ],
    });
  }

  sub prompt_string ($self) {
    my $project = $self->queue->get_current;

    if ($project) {
      return colored_prompt('prompt', "$project->{id} > ");
    }

    return colored_prompt(['cyan'], 'no project > ');
  }

  around interact => sub ($orig, $self) {
    my $project = $self->queue->get_current;

    if (($self->last_interacted_project_id//'') ne $project->{id}) {
      say $self->_project_card($project);
      $self->last_interacted_project_id($project ? $project->{id} : undef);
    }

    if ($self->_do_autoreview) {
      $self->_do_autoreview(0);
      $self->_execute_autoreview({
        stop_on_problems => 1,
        quiet => 1,
      });
    }

    return $self->$orig;
  };

  sub _execute_autoreview ($self, $arg = {})  {
    PROJECT: while (1) {
      my $project = $self->queue->get_current;
      say "Attempting autoreview of $project->{id}" unless $arg->{quiet};

      my $notes = $self->_get_notes($project);

      if (@$notes) {
        if ($arg->{stop_on_problems}) {
          # We hit a project with problems.  Let's stop and work on it.
          cmdnext;
        }

        next PROJECT if $self->queue->maybe_next;
        matesay("We got to the end of the queue!  Okay!");
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
    sub { Yakker::LoopControl::Empty->new->throw },
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

      $self->_execute_autoreview({ stop_on_problems => 1 });
    }
  );

  command 'disown' => (
    help => {
      summary => 'mark this project as never to be reviewed',
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $project = $self->queue->get_current;

      $self->app->_never_review($project->{id});

      okaysay("Sorry, $project->{id}, we wash our hands of you!");

      unless ($self->queue->maybe_next) {
        matesay("Can't go to the next task, because that was the last one!");
        cmdnext;
      }

      $self->_execute_autoreview({ stop_on_problems => 1 });
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

      say $self->_project_card($project);

      cmdnext;
    }
  );

  command 'a.uto.review' => (
    help => {
      summary => "move forward until a project with problems",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      $self->_execute_autoreview({ stop_on_problems => 1 });
    }
  );

  command 'omnireview' => (
    help => {
      summary => "attempt to autoreview every single project",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      $self->_execute_autoreview({ stop_on_problems => 0 });
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
      $self->_execute_autoreview({ stop_on_problems => 1 });
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

  command 'c.pan' => (
    help    => {
      summary => "assume the project is a CPAN dist and open on MetaCPAN",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $name = $self->queue->get_current->{id};

      my $link = "https://metacpan.org/release/$name";
      system("open", $link);
      okaysay "Opened in your browser: $link";
      cmdnext;
    },
  );

  command 'm.eta.data' => (
    help    => {
      summary => "open MetaCPAN release data",
    },
    sub ($self, $cmd, $rest) {
      $self->assert_queue_not_empty;
      my $name = $self->queue->get_current->{id};

      my $dist = $self->app->dist->{$name};

      my $uri = $dist
        ? sprintf('https://fastapi.metacpan.org/release/%s/%s',
                  $dist->@{ qw(author name) })
        : sprintf('https://fastapi.metacpan.org/release/%s', $name);

      my $res = $self->app->http_agent->do_request(
        uri => $uri,
        yakker_label  => "getting release from MetaCPAN",
      )->get;

      # TODO: distinguish 404 from other errors
      unless ($res->is_success) {
        cmderr("Rats, I couldn't get the MetaCPAN resource.");
      }

      open my $less, "|-", "less", "-M";
      my $select = SelectSaver->new($less);
      say $res->decoded_content;
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

  sub _notes_for_project {
    my ($self, $name) = @_;

    my $home = $self->app->_state->{$name}{home} // 'CPAN';

    if ($home eq 'CPAN') {
      return $self->_cpan_notes_for_project($name);
    } elsif ($home eq 'GitHub') {
      return $self->_github_notes_for_project($name);
    }

    return ("not hosted at CPAN, but at $home");
  }

  has _rt_data => (
    is   => 'ro',
    lazy => 1,
    default => sub ($self, @) {
      my %rt_data;
      my $res = $self->app->http_agent->do_request(
        uri => 'https://rt.cpan.org/Public/bugs-per-dist.json',
        yakker_label => "consulting rt.cpan.org",
      )->get;

      die "Can't get RT bug count JSON" unless $res->is_success;
      my $bug_count = $self->app->decode_json_res($res);
      for my $name ($self->app->projects) {
        next unless $bug_count->{$name};
        $rt_data{ $name } = {
          open    => 0,
          stalled => 0,
        };

        $rt_data{ $name }{open} = $bug_count->{$name}{counts}{active}
                                - $bug_count->{$name}{counts}{stalled};

        $rt_data{ $name }{stalled} = $bug_count->{$name}{counts}{stalled};
      }

      return \%rt_data;
    }
  );

  sub _cpan_notes_for_project {
    my ($self, $name) = @_;

    my $dist = $self->app->dist->{$name};

    my ($uri, $get_release);
    if ($dist) {
      $uri = sprintf 'https://fastapi.metacpan.org/release/%s/%s',
        $dist->@{ qw(author name) };
      $get_release = 1;
    } else {
      $uri = sprintf 'https://fastapi.metacpan.org/release/%s', $name;
    }

    my $res = $self->app->http_agent->do_request(
      uri => $uri,
      yakker_label  => "getting release from MetaCPAN",
    )->get;

    # TODO: distinguish 404 from other errors
    return ("couldn't find dist on metacpan") unless $res->is_success;

    my $release = $get_release
                ? $self->app->decode_json_res($res)->{release}
                : $self->app->decode_json_res($res);

    my @notes;

    unless ($release->{metadata}{x_rjbs_perl_window}) {
      push @notes, "no perl-window defined";

      if ($release->{metadata}{x_rjbs_perl_support}) {
        $notes[-1] .= " (but perl-support was)";
      }
    }

    my $tracker = $release->{metadata}{resources}{bugtracker};
    if (! $tracker->{web} or $tracker->{web} =~ /rt.cpan/) {
      push @notes, "still using rt.cpan.org";
    }

    my $gh_repo_name = $name;
    my $gh_user = $self->app->github_id;

    my $repo = $release->{metadata}{resources}{repository}{url};
    if (! $repo) {
      push @notes, "no repository on file";
    } elsif ($repo !~ /github.com/) {
      push @notes, "not using GitHub for repo";
    } elsif ($repo =~ /\Q$name/i && $repo !~ /\Q$name/) {
      $gh_repo_name = lc $name;
      push @notes, "GitHub repo is not capitalized correctly";
    } elsif ($repo =~ m{github\.com/\Q$gh_user\E/(.+?)(?:\.git)}) {
      $gh_repo_name = $1;
    } elsif ($repo =~ m{github\.com/(.+?)(?:\.git)}) {
      $gh_repo_name = $1;
    }

    my $author = $release->{metadata}{author};
    if (grep {; /<rjbs\@cpan\.org>/ } @$author) {
      push @notes, 'rjbs@cpan.org still used as author';
    }

    push @notes, $self->_github_notes_for_project($gh_repo_name);

    my $rt_bugs = $self->_rt_data->{$name};
    for (qw(open stalled)) {
      push @notes, "rt.cpan.org $_ ticket count: $rt_bugs->{$_}"
        if $rt_bugs->{$_};
    }

    unless (($release->{metadata}{generated_by} // '') =~ /Dist::Zilla/) {
      push @notes, "dist not built with Dist::Zilla";
    }

    {
      my $res = $self->app->http_agent->do_request(
        uri => "https://cpants.cpanauthors.org/dist/$name.json",
        yakker_label  => "checking CPANTS",
      )->get;

      if ($res->is_success) {
        my $data = $self->app->decode_json_res($res);
        for my $result (@{ $data->{kwalitee}[0] }) {
          next if $result->{value};
          next if $result->{is_experimental};
          next if $result->{is_extra};
          push @notes, "kwalitee test failed: $result->{name}";
        }
      } else {
        push @notes, "could not get CPANTS results";
      }
    }

    return @notes;
  }

  sub _github_notes_for_project {
    my ($self, $gh_repo_name) = @_;

    my $gh_user = $self->app->github_id;

    my $path = $gh_repo_name =~ m{/}
             ? $gh_repo_name
             : "$gh_user/$gh_repo_name";

    my $res = $self->app->http_agent->do_request(
      uri       => "https://api.github.com/repos/$path",
      headers   => [ Authorization => "token $ENV{GITHUB_OAUTH_TOKEN}"],
      yakker_label => "talking to GitHub",
    )->get;

    unless ($res->is_success) {
      return ("Couldn't get repo data for $gh_user/$gh_repo_name from GitHub");
    }

    my $repo = $self->app->decode_json_res($res);

    my @notes;

    push @notes, "GitHub default branch is master"
      if $repo->{default_branch} eq 'master';

    push @notes, "GitHub issues are not enabled"
      if ! $repo->{has_issues};

    push @notes, "GitHub issue count: $repo->{open_issues_count}"
      if $repo->{open_issues_count};

    return @notes;
  }

  no Moo;
}

no Moo;
1;
