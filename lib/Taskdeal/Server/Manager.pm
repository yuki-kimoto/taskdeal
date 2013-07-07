package Taskdeal::Server::Manager;
use Mojo::Base -base;

use Archive::Tar;
use Carp 'croak';
use File::Find 'find';
use File::Path 'rmtree';

has 'home';
has 'log';

sub roles {
  my $self = shift;
  
  # Search roles
  my $home = $self->home;
  my $dir = "$home/server/roles";
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
  my $dir = "$home/server/roles/$role";
  my @tasks;
  find(sub {
    my $task = $File::Find::name;
    $task =~ s/^\Q$dir//;
    $task =~ s/^\///;
    push @tasks, $task if defined $task && length $task;
  }, $dir);
  
  return \@tasks;
}

sub role_tar {
  my ($self, $role) = @_;
  
  # Archive role
  my $tar = Archive::Tar->new;
  my $home = $self->home;
  my $role_dir = "$home/server/roles/$role";
  chdir $role_dir
    or croak "Can't change directory $role_dir: $!";
  find(sub {
    my $name = $File::Find::name;
    $name =~ s/^\Q$role_dir//;
    return if !defined $name || $name eq '';
    $name =~ s/^\///;
    $tar->add_files($name);
  }, $role_dir);

  my $role_tar = $tar->write;
  
  return $role_tar;
}

1;
