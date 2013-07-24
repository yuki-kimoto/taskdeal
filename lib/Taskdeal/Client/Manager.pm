package Taskdeal::Client::Manager;
use Mojo::Base -base;

use Carp 'croak';
use File::Path 'rmtree';

has 'home';
has 'log';

sub role_dir {
  my $self = shift;
  
  # Role directory
  my $home = $self->home;
  return "$home/client/role";
}

sub role_path {
  my ($self, $role_name) = @_;
  
  # Role path
  my $role_dir = $self->role_dir;
  return "$role_dir/$role_name";
}

sub current_role {
  my $self = shift;
  
  # Search role
  my $home = $self->home;
  my $dir = "$home/client/role";
  opendir my $dh, $dir
    or croak "Can't open directory $dir: $!";
  my @roles;
  while (my $role = readdir $dh) {
    next if $role =~ /^\./ || ! -d "$dir/$role";
    push @roles, $role;
  }
  
  # Check role counts
  my $count = @roles;
  $self->log->warn("client/role directory should contain only one role. Found $count role: @roles")
    if @roles > 1;
  
  return $roles[0];
}

sub cleanup_role {
  my $self = shift;
  
  # Check role directory
  my $home = $self->home;
  my $role_dir = "$home/client/role";
  croak unless -d $role_dir;
  
  # Change directory
  chdir $home
    or croak "Can't change directory $home: $!";
  
  # Cleanup direcotyr
  for my $role (glob "$role_dir/*") {
    next if $role =~ /.gitdironly$/;
    rmtree $role;
  }
}

1;
