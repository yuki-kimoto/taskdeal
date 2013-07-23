package Taskdeal::Server;

use Mojo::Base 'Mojolicious';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../mojo/lib";
use lib "$FindBin::Bin/../extlib/lib/perl5";

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
  my $info_log = Taskdeal::Log->new(path => $home->rel_file('log/server/info.log'));
  $self->info_log($info_log);
  
  # Client command log
  my $client_command_log = Taskdeal::Log->new(
    path => $home->rel_file('log/server/client-command.log')
  );

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
        
        my $type = $params->{type} || '';
        
        use Data::Dumper;
        warn "aaaaaaaaaaaaaaaaaaaaa " . Dumper($params);
        
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
        elsif ($type eq 'role_result') {
          $info_log->info('Recieve role result' . $manager->client_info($cid));
          
          my $message_id = $params->{message_id};
          my $controller = delete $controllers->{$message_id};
          my $message = $params->{message};
          
          if ($params->{ok}) {
            my $current_role = $params->{current_role};
            $current_role = '' unless defined $current_role;
            $dbi->model('client')->update(
              {current_role => $current_role},
              id => $cid
            );
            return $controller->render(json => {ok => 1});
          }
          else {
            return $controller->render(json => {ok => 0, message => $message});
          }
        }
        elsif ($type eq 'task_result') {
          $info_log->info('Recieve task result' . $manager->client_info($cid));
          
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
        elsif ($type eq 'command_log') {
          my $cid = $params->{cid};
          my $line = $params->{line};
          my $client_info = $manager->client_info($cid);
          $client_command_log->info("$client_info $line");
        }
        else {
          if (my $message = $params->{message}) {
            if ($params->{error}) {
              $info_log->error($manager->client_info($cid) . " send error message");
            }
            else {
              $info_log->info($manager->client_info($cid) . " send success message");
            }
          }
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
      
      my $ip = $self->tx->remote_address;
      
      # Admin page ip control
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
      unless ($api->logined_admin) {
        my $path_first = $self->req->url->path->parts->[0] || '';
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

    $r->post('/task' => sub {
      my $self = shift;
      
      my $cid = $self->param('id');
      my $command = $self->param('command');
      
      $clients->{$cid}{controller}->send(json => {
        type => 'task',
        command => $command
      });
    });

    $r->get('/api/tasks' => sub {
      my $self = shift;
      
      my $role = $self->param('role');
      
      my $tasks = $manager->tasks($role);
      
      $self->render(json => {tasks => $tasks});
    });

    $r->post('/api/role/select' => sub {
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
  
  $self->helper(taskdeal_api => sub {
    my $self = shift;
    return Taskdeal::Server::API->new($self);
  });

  $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

1;
