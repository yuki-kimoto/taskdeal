use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../mojo/lib";
use lib "$FindBin::Bin/../extlib/lib/perl5";

# Digest::SHA loading to Mojo::Util
{
  package Mojo::Util;
  eval {require Digest::SHA; import Digest::SHA qw(sha1 sha1_hex)};
}

package Taskdeal::Server;
use Mojo::Base 'Mojolicious';

use Taskdeal::Log;
use Taskdeal::Server::Manager;
use Taskdeal::Server::API;
use Validator::Custom;
use DBIx::Custom;
use Scalar::Util 'weaken';
use Mojolicious::Plugin::AutoRoute::Util 'template';

has 'manager';
has 'dbi';
has 'validator';
has 'info_log';

# Clients
my $clients = {};
my $controllers = {};
my $message_id = 1;
my $groups_h = {};

sub startup {
  my $self = shift;
  
  # Home
  my $home = $self->home;
  
  # Information log
  my $info_log = Taskdeal::Log->new(
    path => $home->rel_file('log/server/info.log'),
    app => $self
  );
  $self->info_log($info_log);
  
  # Client command log
  my $client_terminal_log = Taskdeal::Log->new(
    path => $home->rel_file('log/server/client-terminal.log'),
    app => $self
  );

  # Config
  my $config = $self->plugin('INIConfig', ext => 'conf');

  # Hypnotoad config
  my $hypnotoad = $config->{hypnotoad};
  $hypnotoad->{workers} = 1;
  $hypnotoad->{listen} ||= ['http://*:10040'];

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

  # Validator
  my $validator = Validator::Custom->new;
  $self->validator($validator);
  $validator->register_constraint(
    user_name => sub {
      my $value = shift;
      
      return ($value || '') =~ /^[a-zA-Z0-9_\-]+$/
    }
  );
  
  # Model
  $dbi->create_model({table => 'user', primary_key => 'id'});
  $dbi->create_model({table => 'client', primary_key => 'id'});
  
  # Remove all clients
  $dbi->model('client')->delete_all;
  
  # Routes
  my $r = $self->routes;
  
  # WebSocket
  {
    # Receive
    $r->websocket('/connect' => sub {
      my $self = shift;
      
      # Client id
      my $object_id = "$self";
      my ($cid) = $object_id =~ /\(0x(.+?)\)$/;
      
      # Resist controller
      $clients->{$cid}{controller} = $self;
      
      # Register Client information
      my $params = {
        id => $cid,
        host => $self->tx->remote_address,
        port => $self->tx->remote_port
      };
      $dbi->model('client')->insert($params);
      
      # Connected message
      $info_log->info("Success Websocket Handshake. " . $manager->client_info($cid));
      
      # Receive client params
      $self->on(json => sub {
        my ($tx, $params) = @_;
        
        # Type
        my $type = $params->{type} || '';
        
        # Client info
        if ($type eq 'client_info') {
          
          # Create client information
          my $p = {};
          $p->{name} = defined $params->{name} ? $params->{name} : '';
          $p->{current_role}
            = defined $params->{current_role} ? $params->{current_role} : '';
          $p->{client_group} = defined $params->{group} ? $params->{group} : '';
          $p->{description}
            = defined $params->{description} ? $params->{description} : '';
          $dbi->model('client')->update($p, id => $cid);
          
          # Log client connect
          $info_log->info("Client Connect. " . $manager->client_info($cid));
        }
        
        # Role result
        elsif ($type eq 'role_result') {
          $info_log->info('Recieve role result' . $manager->client_info($cid));
          
          # Parameters
          my $message_id = $params->{message_id};
          my $controller = delete $controllers->{$message_id};
          my $message = $params->{message};
          
          # Result success
          if ($params->{ok}) {
            my $current_role = $params->{current_role};
            $current_role = '' unless defined $current_role;
            $dbi->model('client')->update(
              {current_role => $current_role},
              id => $cid
            );
            return $controller->render(json => {ok => 1});
          }
          # Result error
          else {
            return $controller->render(json => {ok => 0, message => $message});
          }
        }
        
        # Task result
        elsif ($type eq 'task_result') {
          $info_log->info('Recieve task result' . $manager->client_info($cid));
          
          # Parameters
          my $message_id = $params->{message_id};
          my $controller = delete $controllers->{$message_id};
          my $message = $params->{message};
          
          # Result success
          if ($params->{ok}) {
            return $controller->render(json => {ok => 1});
          }
          
          # Result error
          else {
            return $controller->render(json => {ok => 0, message => $message});
          }
        }
        
        # Command log
        elsif ($type eq 'command_log') {
          my $cid = $params->{cid};
          my $line = $params->{line};
          my $client_info = $manager->client_info($cid);
          $client_terminal_log->info("$client_info $line");
        }
      });
      
      # Client disconnected
      $self->on('finish' => sub {
        # Remove client
        my $info = $manager->client_info($cid);
        delete $clients->{$cid};
        $dbi->model('client')->delete(id => $cid);
        $info_log->info("Client Disconnect. " . $info);
      });
    });
  }
  
  # HTTP access
  {
    my $r = $r->under(sub {
      my $self = shift;
      
      # Admin page ip control
      my $ip = $self->tx->remote_address;
      unless ($manager->is_allow($ip, %{$config->{ip_control_admin}})) {
        $self->res->code('403');
        return;
      }
      
      # Client ip control
      unless ($manager->is_allow($ip, %{$config->{ip_control_client}})) {
        $self->res->code('403');
        return;
      }
      
      # Check login
      my $api = $self->taskdeal_api;
      my $path_first = $self->req->url->path->parts->[0] || '';
      if (!defined $manager->admin_user) {
        unless ($path_first eq '_start') {
          $self->redirect_to('/_start');
          return;
        }
      }
      elsif (!$api->logined_admin) {
        unless ($path_first eq '_login') {
          $self->redirect_to('/_login');
          return;
        }
      }
      
      return 1;
    });
    
    # DBViewer(only development)
    if ($self->mode eq 'development') {
      eval {
        $self->plugin(
          'DBViewer',
          dsn => "dbi:SQLite:database=$db_file",
          route => $r
        );
      };
    }
    
    # AutoRoute
    $self->plugin('AutoRoute', route => $r);
    
    # Get tasks
    $r->get('/api/tasks' => sub {
      my $self = shift;
      
      my $role = $self->param('role');
      
      my $tasks = $manager->tasks($role);
      
      $self->render(json => {tasks => $tasks});
    });
    
    # Update role
    $r->post('/api/role/update' => sub {
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
            type => 'role',
            role_name => $role,
            role_tar => $role_tar,
            message_id => $mid
          }
        });
        $info_log->info('Send role command' . $manager->client_info($cid));
        $self->render_later;
      }
      else {
        $self->render(json => {ok => 0, message => 'Client[ID:262f1b8] not found'});
      }
    });
    
    # Execute task
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
          cid => $cid,
          message_id => $mid
        }
      });
      $info_log->info('Send task command' . $manager->client_info($cid));
      $self->render_later;
    });
  }
  
  # API
  $self->helper(taskdeal_api => sub {
    my $self = shift;
    return Taskdeal::Server::API->new($self);
  });

  $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

1;
