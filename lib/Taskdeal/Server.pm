package Taskdeal::Server;
use Mojo::Base -base;

use Carp 'croak';
use File::Find 'find';

has 'home';

sub roles {
  my $self = shift;
  
  # Search roles
  my $home = $self->home;
  my $dir = "$home/roles";
  opendir my $dh, $dir
    or croak "Can't open directory $dir: $!";
  my @roles;
  while (my $role = readdir $dh) {
    next if $role =~ /^\./ || ! -d "$dir/$role";
    push @roles, $role;
  }
  
  # Check role counts
  
  return \@roles;
}

sub tasks {
  my ($self, $role) = @_;
  
  return unless defined $role;
  
  # Search tasks
  my $home = $self->home;
  my $dir = "$home/roles/$role";
  my @tasks;
  find(sub {
    my $task = $File::Find::name;
    $task =~ s/^\Q$dir//;
    $task =~ s/^\///;
    push @tasks, $task if defined $task && length $task;
  }, $dir);
  
  return \@tasks;
}

1;
