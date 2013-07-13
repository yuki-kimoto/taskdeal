package Taskdeal::Server;

use Mojo::Base 'Mojolicious';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../mojo/lib";
use lib "$FindBin::Bin/../extlib/lib/perl5";

use Taskdeal::Log;
use Taskdeal::Server::Manager;
use DBIx::Custom;
use Scalar::Util 'weaken';

has 'manager';
has 'dbi';

# Clients
my $clients = {};
my $controllers = {};
my $message_id = 1;
my $groups_h = {};

sub startup {
  my $self = shift;
  
  # Home
  my $home = $self->home;
  
  # Log
  my $log = Taskdeal::Log->new(path => $home->rel_file('log/taskdeal-server.log'));
  $self->log($log);

  # Config
  my $config = $self->plugin('INIConfig', ext => 'conf');

  # Workers is always 1
  my $hypnotoad = $config->{hypnotoad};
  $hypnotoad->{workers} = 1;

  # Tasks directory
  my $tasks_dir = $home->rel_dir('tasks');

  # Manager
  my $manager = Taskdeal::Server::Manager->new(home => $home->to_string, app => $self);
  weaken $manager->{app};
  $self->manager($manager);
  
  # DBI
  my $db_file = $self->home->rel_file('data/taskdeal.db');
  my $dbi = DBIx::Custom->connect(
    dsn => "dbi:SQLite:database=$db_file",
    connector => 1,
    option => {sqlite_unicode => 1, sqlite_use_immediate_transaction => 1}
  );
  $self->dbi($dbi);
  
  # Setup database
  $manager->setup_database;

  # Model
  $dbi->create_model({table => 'client', primary_key => 'id'});
  
  # Remove all clients
  $dbi->model('client')->delete_all;
  
  # Client information
  my $client_info = sub {
    my $cid = shift;
    
    my $row = $dbi->model('client')->select(id => $cid)->one;
    
    my $name = $row->{name};
    my $group = $row->{group};
    my $host = $row->{host};
    my $port = $row->{port};
    
    my $info = "[";
    $info .= "Name:$name, " if length $name;
    $info .= "Group:$group, " if length $group;
    $info .= "Host:$host:$port, ID:$cid]";
    
    return $info;
  };
  
  # Routes
  my $r = $self->routes;
  
  # Receive
  $r->websocket('/' => sub {
    my $self = shift;
    
    # Client id
    my $object_id = "$self";
    my ($cid) = $object_id =~ /\(0x(.+?)\)$/;
    
    # Resist controller
    $clients->{$cid}{controller} = $self;
    
    # Client host
    my $client_host = $self->tx->remote_address;
    $clients->{$cid}{host} = $client_host;
    
    # Remote port
    my $client_port = $self->tx->remote_port;
    $clients->{$cid}{port} = $client_port;
    
    # Connected message
    $log->info("Success Websocket Handshake. " . $client_info->($cid));
    
    # Receive client params
    $self->on(json => sub {
      my ($tx, $params) = @_;
      
      my $type = $params->{type} || '';
      
      if ($type eq 'client_info') {
        
        my $p = {};
        
        $p->{id} = $cid;
        $p->{name} = $params->{name};
        $p->{name} = '' unless defined $p->{name};
        $p->{current_role} = $params->{current_role};
        $p->{current_role} = '' unless defined $p->{current_role};
        $p->{group} = $params->{group};
        $p->{group} = '' unless defined $p->{group};
        $p->{host} = $clients->{$cid}{host};
        $p->{port} = $clients->{$cid}{port};
        $dbi->model('client')->insert($p);
        
        $log->info("Client Connect. " . $client_info->($cid));
      }
      elsif ($type eq 'sync_result') {
        $log->info('Recieve sync result' . $client_info->($cid));
        
        my $message_id = $params->{message_id};
        my $controller = delete $controllers->{$message_id};
        my $message = $params->{message};
        
        if ($params->{ok}) {
          use Data::Dumper;
          $clients->{$cid}{current_role} = $params->{current_role};
          return $controller->render(json => {ok => 1});
        }
        else {
          return $controller->render(json => {ok => 0, message => $message});
        }
      }
      elsif ($type eq 'task_result') {
        $log->info('Recieve task result' . $client_info->($cid));
        
        my $message_id = $params->{message_id};
        my $controller = delete $controllers->{$message_id};
        my $message = $params->{message};
        
        if ($params->{ok}) {
          return $controller->render(json => {ok => 1});
        }
        else {
          return $controller->render(json => {ok => 0, message => $message});
        }
      }
      else {
        if (my $message = $params->{message}) {
          if ($params->{error}) {
            $log->error($client_info->($cid) . " send error message");
          }
          else {
            $log->info($client_info->($cid) . " send success message");
          }
        }
      }
    });
    
    # Client disconnected
    $self->on('finish' => sub {
      # Remove client
      my $info = $client_info->($cid);
      delete $clients->{$cid};
      $dbi->model('client')->delete(id => $cid);
      $log->info("Client Disconnect. " . $info);
    });
  });

  $r->post('/task' => sub {
    my $self = shift;
    
    my $cid = $self->param('id');
    my $command = $self->param('command');
    
    $clients->{$cid}{controller}->send(json => {
      type => 'task',
      command => $command
    });
  });

  $r->get('/' => sub {
    my $self = shift;
    
    # Render
    $self->render('/index');
  });

  $r->get('/api/tasks.json' => sub {
    my $self = shift;
    
    my $role = $self->param('role');
    
    my $tasks = $manager->tasks($role);
    
    $self->render(json => {tasks => $tasks});
  });

  $r->post('/api/role/sync' => sub {
    my $self = shift;
    
    # Controllers
    my $mid = $message_id++;
    $controllers->{$mid} = $self;
    
    # Sync role
    my $cid = $self->param('cid');
    my $role = $self->param('role');
    my $role_tar = defined $role && length $role ? $manager->role_tar($role) : undef;
    my $c = $clients->{$cid}{controller};
    if ($c) {
      $c->send({
        json => {
          type => 'sync',
          role_name => $role,
          role_tar => $role_tar,
          message_id => $mid
        }
      });
      $log->info('Send sync command' . $client_info->($cid));
      $self->render_later;
    }
    else {
      $self->render(json => {ok => 0, message => 'Client[ID:262f1b8] not found'});
    }
  });
  
  $r->post('/api/task/execute' => sub {
    my $self = shift;
    
    # Controllers
    my $mid = $message_id++;
    $controllers->{$mid} = $self;
    
    # Send task command
    my $cid = $self->param('cid');
    my $role = $self->param('role');
    my $task = $self->param('task');
    $clients->{$cid}{controller}->send({
      json => {
        type => 'task',
        role => $role,
        task => $task,
        message_id => $mid
      }
    });
    $log->info('Send task command' . $client_info->($cid));
    $self->render_later;
  });

  $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

1;
