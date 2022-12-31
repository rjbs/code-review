package RJBS::CodeReview::Activity::Boot;
use v5.36.0;
use utf8;

use Moo;
with 'Yakker::Role::Activity';

use RJBS::CodeReview::ReviewQueue;

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
1;
