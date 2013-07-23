package Taskdeal::Client;
use Mojo::Base 'Mojolicious';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../mojo/lib";
use lib "$FindBin::Bin/../extlib/lib/perl5";

use Config::Tiny;
use Taskdeal::Log;
use Taskdeal::Client::Manager;
use Mojo::UserAgent;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';
use Archive::Tar;
use File::Path qw/mkpath rmtree/;

# Reconnet interval
my $reconnect_interval = 5;

sub startup {
  my $self = shift;

  # Home
  my $home = $self->home;
  $ENV{TASKDEAL_HOME} = "$home";
  
  # Information log
  my $info_log = Taskdeal::Log->new(path => $home->rel_file('log/client/info.log'));
  
  # Command log
  my $command_log = Taskdeal::Log->new(path => $home->rel_file('log/client/command.log'));

  # Manager
  my $manager = Taskdeal::Client::Manager->new(home => "$home", log => $info_log);

  # Config
  $self->plugin('INIConfig', ext => 'conf');
  
  # Config for development
  my $my_conf_file = $self->home->rel_file('taskdeal-client.my.conf');
  $self->plugin('INIConfig', {file => $my_conf_file}) if -f $my_conf_file;
  my $config = $self->config;
  
  # hypnotoad config
  my $hypnotoad = $config->{hypnotoad};
  my $port = Mojo::IOLoop->generate_port;
  $hypnotoad->{listen} = ["http://*:$port"];

  # User Agent
  my $ua = Mojo::UserAgent->new;
  $ua->inactivity_timeout(0);

  # Server URL
  my $server_host = $config->{server}{host} || 'localhost';
  my $server_url = "ws://$server_host";
  my $server_port = $ENV{TASKDEAL_SERVER_PORT} || $config->{server}{port} || '10040';
  $server_url .= ":$server_port";
  $server_url .= "/connect";
  
  # IOLoop
  Mojo::IOLoop->timer(0 => sub {
    # Connect to server
    my $websocket_cb;
    $websocket_cb = sub {
      $ua->websocket($server_url => sub {
        my ($ua, $tx) = @_;
        
        # Web socket connection success
        if ($tx->is_websocket) {
          $info_log->info("Connect to $server_url.");
          
          # Send client information
          my $current_role = $manager->current_role;
          my $name = $config->{client}{name};
          $name = hostname unless defined $name;
          my $group = $config->{client}{group};
          my $description = $config->{client}{description};
          $tx->send({json => {
            type => 'client_info',
            current_role => $current_role,
            name => $name,
            group => $group,
            description => $description
          }});
          
          # Receive JSON message
          $tx->on(json => sub {
            my ($tx, $hash) = @_;
            
            my $type = $hash->{type} || '';
            
            if ($type eq 'role') {
              my $role_name = $hash->{role_name};
              my $role_tar = $hash->{role_tar};

              $info_log->info("Receive role command. Role is $role_name");

              my $result = {
                type => 'role_result',
                message_id => $hash->{message_id},
                cid => $hash->{cid}
              };
              
              if (defined $role_name && length $role_name) {
                if (open my $fh, '<', \$role_tar) {
                  my $role_path = "$home/client/role/$role_name";
                  mkpath $role_path;
                  
                  my $tar = Archive::Tar->new;
                  $tar->setcwd($role_path);
                  if ($tar->read($fh)) {
                    eval { $manager->cleanup_role };
                    if ($@) {
                      my $message = "Error: cleanup role: $@";
                      $info_log->error($message);
                      $result->{ok} = 0;
                      $result->{message} = $message;
                      $tx->send({json => $result});
                    }
                    else {
                      $tar->extract;
                      $result->{ok} = 1;
                      $result->{current_role} = $role_name;
                      $tx->send({json => $result});
                    }
                  }
                  else {
                    my $message = "Error: Can't read role tar: $!";
                    $info_log->error($message);
                    $result->{ok} = 0;
                    $result->{message} = $message;
                    $tx->send({json => $result});
                  }
                }
                else {
                  my $message = "Error: Can't open role tar: $!";
                  $info_log->error($message);
                  $result->{ok} = 0;
                  $result->{message} = $message;
                  $tx->send({json => $result});
                }
              }
              else {
                eval { $manager->cleanup_role };
                if ($@) {
                  my $message = "Error: cleanup role: $@";
                  $info_log->error($message);
                  $result->{ok} = 0;
                  $result->{message} = $message;
                  $tx->send({json => $result});
                }
                else {
                  $result->{ok} = 1;
                  $result->{current_role} = undef;
                  $tx->send({json => $result});
                }
              }
            }
            elsif ($type eq 'task') {
              my $role = $hash->{role};
              my $work_dir = "$home/client/role/$role";
              my $task = $hash->{task};
              my $cid = $hash->{cid};
              
              $info_log->info("Receive task command. Role is $role. Task is $task.");
              
              my $result = {
                type => 'task_result',
                message_id => $hash->{message_id}
              };
              
              if (chdir $work_dir) {
                my $task_re = qr/[a-zA-Z0-9_-]+/;
                
                if (defined $task && $task =~ /$task_re/) {
                  my $command = "./$task 2>&1";
                  my $success = open my $fh, "$command |";
                  $command_log->info("$command");
                  
                  $tx->send({json => {
                    type => 'command_log',
                    cid => $cid,
                    message_id => $hash->{message_id},
                    line => "$command"
                  }});
                  
                  if ($success) {
                    while (my $line = <$fh>) {
                      $command_log->info($line);
                      $tx->send({json => {
                        type => 'command_log',
                        cid => $cid,
                        message_id => $hash->{message_id},
                        line => $line
                      }});
                    }
                    my $status = `echo $?`;
                    if (($status || '') =~ /^0/) {
                      my $message = "Task $task success.";
                      $info_log->info($message);
                      $result->{message} = $message;
                      $result->{ok} = 1;
                      $tx->send({json => $result});
                    }
                    else {
                      my $message = "Task $task fail(Return bad status).";
                      $info_log->error($message);
                      $result->{message} = $message;
                      $result->{ok} = 0;
                      $tx->send({json => $result});
                    }
                  } else {
                    my $message = "Task $task fail(Can't execute command).";
                    $info_log->error($message);
                    $result->{message} = $message;
                    $result->{ok} = 0;
                    $tx->send({json => $result});
                  }
                }
                else {
                  my $message = "Task $task fail(Tas contains invalid character).";
                  $info_log->error($message);
                  $result->{message} = $message;
                  $result->{ok} = 0;
                  $tx->send({json => $result});
                }
              }
              else {
                my $message = "Task $task fail(Can't change directory $work_dir: $!).";
                $info_log->error($message);
                $result->{message} = $message;
                $result->{ok} = 0;
                $tx->send({json => $result});
              }
            }
            else {
              my $message = "Unknown type $type";
              my $result = {
                type => 'unknown_result',
                message_id => $hash->{message_id},
                message => $message,
                ok => 0
              };
              $info_log->error($message);
              $tx->send({json => $result});
            }
          });
          
          # Finish websocket connection
          $tx->on(finish => sub {
            $info_log->info("Disconnected.");
            
            # Reconnect to server
            Mojo::IOLoop->timer($reconnect_interval => sub { goto $websocket_cb });
          });
        }
        
        # Web socket connection fail
        else {
          $info_log->error("Can't connect to server: $server_url.");
          
          # Reconnect to server
          Mojo::IOLoop->timer($reconnect_interval => sub { goto $websocket_cb });
        }
      });
    };
    $websocket_cb->();
  });
  
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}
