package Taskdeal::Server::Manager;
use Mojo::Base -base;

use Archive::Tar;
use Carp 'croak';
use File::Find 'find';
use File::Path 'rmtree';

has 'home';
has 'app';

sub admin_user {
  my $self = shift;
  
  # Admin user
  my $admin_user = $self->app->dbi->model('user')
    ->select(where => {admin => 1})->one;
  
  return $admin_user;
}

sub client_info {
  my ($self, $cid) = @_;
  
  my $row = $self->app->dbi->model('client')->select(id => $cid)->one;
  
  my $name = $row->{name};
  my $group = $row->{group};
  my $host = $row->{host};
  my $port = $row->{port};
  
  my $info = "[";
  $info .= "Name:$name, " if length $name;
  $info .= "Group:$group, " if length $group;
  $info .= "Host:$host:$port, ID:$cid]";
  
  return $info;
}

sub is_allow {
  my ($self, $ip, %opt) = @_;
  
  return 1 if $ip eq '127.0.0.1' || '::1';
  
  my $deny = $opt{deny};

  if (my $allow_str = $opt{allow}) {
    my @allow = split / *, */, $allow_str;
    
    if (grep { $_ eq $ip } @allow) {
      return 1;
    }
    else {
      return;
    }
  }
  elsif (my $deny_str = $opt{deny}) {
    my @deny = split / *, */, $deny_str;
    if (grep { $_ eq $ip } @deny) {
      return;
    }
    else {
      return 1;
    }
  }
  
  return 1;
}

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

sub setup_database {
  my $self = shift;
  
  my $dbi = $self->app->dbi;
  
  # Create user table
  eval {
    my $sql = <<"EOS";
create table user (
  row_id integer primary key autoincrement,
  id not null unique default ''
);
EOS
    $dbi->execute($sql);
  };

  # Create user columns
  my $user_columns = [
    "admin not null default '0'",
    "password not null default ''",
    "salt not null default ''"
  ];
  for my $column (@$user_columns) {
    eval { $dbi->execute("alter table user add column $column") };
  }
  
  # Check user table
  eval { $dbi->select([qw/row_id id admin password salt/], table => 'user') };
  if ($@) {
    my $error = "Can't create user table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
  
  # Create client table
  eval {
    my $sql = <<"EOS";
create table client (
  row_id integer primary key autoincrement,
  id not null unique default ''
);
EOS
    $dbi->execute($sql);
  };

  # Create client columns
  my $client_columns = [
    "client_group not null default ''",
    "name not null default ''",
    "description not null default ''",
    "host not null default ''",
    "port not null default ''",
    "current_role not null default ''"
  ];
  for my $column (@$client_columns) {
    eval { $dbi->execute("alter table client add column $column") };
  }
  
  # Check client table
  eval {
    $dbi->select(
      {client => [qw/row_id id client_group name description host port/]},
      table => 'client'
    );
  };
  if ($@) {
    my $error = "Can't create client table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
}

1;
