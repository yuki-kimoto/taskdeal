package Taskdeal::Server;

use Mojo::Base 'Mojolicious';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../mojo/lib";
use lib "$FindBin::Bin/../extlib/lib/perl5";

use Taskdeal::Log;
use Taskdeal::Manager;

has 'manager';

# Clients
my $clients = {};

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
  my $manager = Taskdeal::Manager->new(home => $home->to_string);
  $self->manager($manager);

  # Client information
  my $client_info = sub {
    my $cid = shift;
    
    my $name = $clients->{$cid}{name};
    my $group = $clients->{$cid}{group};
    my $host = $clients->{$cid}{host};
    my $port = $clients->{$cid}{port};
    
    my $info = "[";
    $info .= "Name:$name, " if defined $name;
    $info .= "Group:$group, " if defined $group;
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
    
    # Receive client result
    $self->on(json => sub {
      my ($tx, $result) = @_;
      
      my $type = $result->{type} || '';
      
      if ($type eq 'client_info') {
        $clients->{$cid}{current_task} = $result->{current_task};
        $clients->{$cid}{name} = $result->{name};
        $clients->{$cid}{group} = $result->{group};
        $clients->{$cid}{description} = $result->{description};
        
        $log->info("Client Connect. " . $client_info->($cid));
      }
      elsif ($type eq 'sync_result') {
        warn 'sync result';
      }
      else {
        if (my $message = $result->{message}) {
          if ($result->{error}) {
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
    $self->render(
      '/index',
      clients => $clients,
    );
  });

  $r->get('/api/tasks.json' => sub {
    my $self = shift;
    
    my $role = $self->param('role');
    
    my $tasks = $manager->tasks($role);
    
    $self->render(json => {tasks => $tasks});
  });

  $r->post('/api/sync' => sub {
    my $self = shift;
    
    my $cid = $self->param('cid');
    my $role = $self->param('role');
    
    if ($clients->{$cid}{lock}) {
      $self->render(json => {ok => 0, error => 'locked'});
    }
    else {
      $clients->{$cid}{lock} = 1;
      delete $clients->{$cid}{sync_result};
      
      my $role_tar = $manager->role_tar($role);
      $clients->{$cid}{controller}->send({json => {type => 'sync', role_name => $role, role_tar => $role_tar}} => sub {
         $log->info('Sync ' . $client_info->($cid));
         my $id;
         $id = Mojo::IOLoop->recurring(1 => sub {
           my $sync_result = $clients->{$cid}{sync_result};
           if ($sync_result) {
             Mojo::IOLoop->remove($id);
             $clients->{$cid}{lock} = 0;
             if ($sync_result->{ok}) {
               return $self->render(json => {ok => 1});
             }
             else {
               return $self->render(json => {ok => 0, error => 'command-failed'});
             }
           }
         });
      });
      
      $self->render_later;
    }
  });

  $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

1;
