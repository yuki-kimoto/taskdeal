package Taskdeal::Client::Log;
use Mojo::Base 'Mojo::Log';

sub log {
  my ($self, $level, $message) = @_;

  my ($pkg, $file, $line) = caller;
  $self->SUPER::log($level, $message);
  warn "$message at $file line $line\n" if $ENV{TASKDEAL_DEBUG};
}

1;
