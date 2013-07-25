package Taskdeal::Log;
use Mojo::Base 'Mojo::Log';

has 'app';

sub log {
  my ($self, $level, $message) = @_;
  
  # Log
  my ($pkg, $file, $line) = caller;
  $self->SUPER::log($level, $message);
  warn "$message\n" if $self->app->mode eq 'development';
}

1;
