package RJBS::CodeReview::Activity::Boot;

use v5.36.0;
use utf8;

use Moo;
with 'Yakker::Role::Activity';

use RJBS::CodeReview::ReviewQueue;

use DateTime;
use DateTime::Format::Strptime;
use List::AllUtils qw(part);
use Time::Duration::Parse;
use YAML::XS ();

has filter_list => (
  is => 'ro',
);

has filter_rules => (
  is => 'ro',
);

has rebuild_only => (
  is => 'ro',
);

sub interact ($self) {
  my $mate = $self->app;

  my $res = $mate->http_agent->do_request(
    uri      => 'https://fastapi.metacpan.org/release/latest_by_author/RJBS',
    yakker_label => "consulting MetaCPAN",
  )->get;

  die "Can't get latest CPAN releases" unless $res->is_success;
  my $releases = $mate->decode_json_res($res);

  my %is_tracked = map {; $_ => ($mate->_state->{$_}{review} // '') ne 'never' }
                   keys $mate->_state->%*;

  my $dist = $mate->dist;

  DIST: for my $d ($releases->{releases}->@*) {
    my $name = $d->{distribution};
    next if $name eq 'perl';

    $is_tracked{$name} = 1 unless exists $is_tracked{$name};
    $dist->{ $name } = $d;
  }

  my @projects = grep {; $is_tracked{$_} } keys %is_tracked;

  my $strp = DateTime::Format::Strptime->new(
    pattern   => '%F',
    locale    => 'en_US',
    time_zone => 'local',
  );

  my ($undue, $due) = part {
    return 0 unless my $rev = $mate->_state->{$_}{'review-every'};
    die "can't parse duration $rev\n" unless my $dur = parse_duration($rev);
    return 1 if ! $mate->_state->{$_}{'last-review'};
    my $last_done = $strp->parse_datetime($mate->_state->{$_}{'last-review'})
                         ->epoch;
    return 1 if time - $last_done > $dur;
    return 0;
  } @projects;

  @projects = (@{ $due // [] }, sort {
    ($mate->_state->{$a}{'last-review'} // 0)
    cmp
    ($mate->_state->{$b}{'last-review'} // 0)

    ||

    fc $a cmp fc $b
  } @$undue);

  my @to_consider = @projects;

  if ($self->filter_list->@*) {
    my @missing = grep {; ! ($is_tracked{$_} or $mate->_state->{$_}) }
                  $self->filter_list->@*;

    die "these projects that you asked about are unknown: @missing\n"
      if @missing;

    @to_consider = $self->filter_list->@*;
  }

  if (!$self->filter_list->@* && $self->filter_rules->%*) {
    my %rules = $self->filter_rules->%*;

    my $res = $mate->http_agent->do_request(
      uri => 'https://www.cpan.org/modules/06perms.txt',
      yakker_label => "consulting CPAN",
    )->get;

    die "Can't get latest CPAN 06perms" unless $res->is_success;
    my @perms_lines = split /\n/, $res->decoded_content;

    my %perm;
    for my $line (@perms_lines) {
      next unless $line =~ /,[a-z]\z/;
      my ($pm, $owner, $type) = split /,/, $line;

      $perm{$pm}{$owner} = $type;
    }

    my @keep;
    PROJECT: for my $project (@to_consider) {
      my $pm_name = $project =~ s/-/::/gr;
      my $perms   = $perm{$pm_name};

      if ($rules{noorphans}) {
        next PROJECT if $perms && ($perms->{ADOPTME}//'') eq 'f';
      }

      if ($rules{noaliens}) {
        next PROJECT if $perms && ! $perms->{ $mate->pause_id };
      }

      push @keep, $project;
    }

    @to_consider = @keep;
  }

  $mate->set_projects(\@projects);
  $mate->set_filtered_projects(\@to_consider);

  if ($self->rebuild_only) {
    $mate->_commit_state;
    Yakker::LoopControl::Pop->new->throw;
  }

  my $activity = $mate->activity(
    'review',
    {
      begin_with_autoreview => 1,
      queue => RJBS::CodeReview::ReviewQueue->new({
        items => [ map {; +{ id => $_ } } $mate->filtered_projects ],
        query => undef, # XXX This is obviously stupid. -- rjbs, 2021-06-17
      }),
    },
  );

  Yakker::LoopControl::Swap->new({ activity => $activity })->throw;
}

no Moo;
1;
