package Taskdeal::API;
use Mojo::Base -base;

has 'cntl';

sub log {
  my ($self, $level, $message) = @_;
  
  my ($pkg, $file, $line) = caller;
  
  $self->cntl->app->log->log($level, $message);
  warn "$message at $file line $line\n" if $ENV{TASKDEAL_DEBUG};
}

1;
