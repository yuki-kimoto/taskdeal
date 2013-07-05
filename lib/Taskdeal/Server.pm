package Taskdeal::Server;
use Mojo::Base -base;

use Carp 'croak';

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

1;
