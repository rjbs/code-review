package RJBS::CodeReview::ReviewQueue;

use v5.36.0;
use utf8;

use Moo;
with 'Yakker::Role::Queue';

sub inflate ($self, $key) {
  return { id => $key };
}

no Moose;
1;
