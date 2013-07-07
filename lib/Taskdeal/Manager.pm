package Taskdeal::Manager;
use Mojo::Base -base;

use Archive::Tar;
use Carp 'croak';
use File::Find 'find';
use Cwd 'cwd';
use File::Path 'rmtree';

has 'home';
has 'log';

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

sub role_tar {
  my ($self, $role) = @_;
  
  # Archive role
  my $tar = Archive::Tar->new;
  my $home = $self->home;
  my $role_dir = "$home/roles/$role";
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

sub current_role {
  my $self = shift;
  
  # Search role
  my $home = $self->home;
  my $dir = "$home/role_client";
  opendir my $dh, $dir
    or croak "Can't open directory $dir: $!";
  my @roles;
  while (my $role = readdir $dh) {
    next if $role =~ /^\./ || ! -d "$dir/$role";
    push @roles, $role;
  }
  
  # Check role counts
  my $count = @roles;
  $self->log->warn("role_client directory should contain only one role. Found $count role: @roles")
    if @roles > 1;
  
  return $roles[0];
}

sub cleanup_role {
  my $self = shift;
  
  my $home = $self->home;
  my $role_dir = "$home/role_client";
  
  croak unless -d $role_dir;
  
  for my $role (glob "$role_dir/*") {
    next if $role =~ /.gitdironly$/;
    rmtree $role;
  }
}

1;
