package Taskdeal::Server::Manager;
use Mojo::Base -base;

use Archive::Tar;
use Carp 'croak';
use File::Find 'find';
use File::Path 'rmtree';

has 'home';

sub roles_dir {
  my $self = shift;
  
  my $home = $self->home;
  
  return "$home/server/roles";
}

sub role_path {
  my ($self, $role_name) = @_;
  
  my $roles_dir = $self->roles_dir;
  my $role_path = "$roles_dir/$role_name";
  
  return $role_path;
}

sub roles {
  my $self = shift;
  
  # Search roles
  my $home = $self->home;
  my $roles_dir = $self->roles_dir;
  opendir my $dh, $roles_dir
    or croak "Can't open directory$roles_dir: $!";
  my @roles;
  while (my $role = readdir $dh) {
    next if $role =~ /^\./ || ! -d "$roles_dir/$role";
    push @roles, $role;
  }
  
  # Check role counts
  
  return \@roles;
}

sub tasks {
  my ($self, $role_name) = @_;
  
  return unless defined $role_name;
  
  my $role_path = $self->role_path($role_name);
  
  # Search tasks
  my @tasks;
  find(sub {
    my $task = $File::Find::name;
    $task =~ s/^\Q$role_path//;
    $task =~ s/^\///;
    push @tasks, $task if defined $task && length $task;
  }, $role_path);
  
  return \@tasks;
}

sub role_tar {
  my ($self, $role_name) = @_;
  
  # Archive role
  my $tar = Archive::Tar->new;
  my $role_path = $self->role_path($role_name);
  chdir $role_path
    or croak "Can't change directory $role_path: $!";
  find(sub {
    my $name = $File::Find::name;
    $name =~ s/^\Q$role_path//;
    return if !defined $name || $name eq '';
    $name =~ s/^\///;
    $tar->add_files($name);
  }, $role_path);

  my $role_tar = $tar->write;
  
  return $role_tar;
}

1;
