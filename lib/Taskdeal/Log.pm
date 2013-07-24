package Taskdeal::Log;
use Mojo::Base 'Mojo::Log';

sub log {
  my ($self, $level, $message) = @_;
  
  # Log
  my ($pkg, $file, $line) = caller;
  $self->SUPER::log($level, $message);
  warn "$message\n" if $ENV{TASKDEAL_DEBUG};
}

1;
