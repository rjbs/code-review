package RJBS::CodeReview;

use v5.30.0;
use warnings;
use utf8;

use Moo;
with 'Yakker::App';

use experimental 'signatures';

use JSON::MaybeXS ();
use List::AllUtils qw(uniq);

use RJBS::CodeReview::Activity::Boot;
use RJBS::CodeReview::Activity::Review;

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

no Moo;
1;
