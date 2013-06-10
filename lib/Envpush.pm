package Envpush;
use Mojo::Base 'Mojolicious';
use Carp 'croak';
use Mojo::UserAgent;

sub startup {
  my $self = shift;
  my $app = $self;
  
  # Config
  my $config = $self->plugin('INIConfig', ext => 'conf');
  
  # Workers is always 1
  my $hypnotoad = $config->{hypnotoad};
  $hypnotoad->{workers} = 1;
  
  # Port
  my $is_parent = ($config->{basic}{type} || '') eq 'parent';

  if ($is_parent) {
    $hypnotoad->{listen} ||= 'ws://*:10040';
  }
  else {
    $hypnotoad->{listen} ||= 'ws://*:10041';
  }
  
  # Task directory
  my $task_dir = $self->home->rel_dir('task');

  my $r = $self->routes;
  
  # Parent
  if ($is_parent) {

    my $childs = {};
    
    $r->websocket('/' => sub {
      my $self = shift;
      
      # Child id
      my $cid = "$self";
      
      # Resist controller
      $childs->{$cid} = $self;
      
      # Receive
      $self->on(json => sub {
        my ($tx, $hash) = @_;
        
        my $remote_address = $tx->remote_address;
        
        if (my $message = $hash->{message}) {
          if ($hash->{error}) {
            $app->log->error("$message(From child $remote_address)");
          }
          else {
            $app->log->info("$message(From hild $remote_address)");
          }
        }
      });
      
      # Finish
      $self->on('finish' => sub {
        # Remove child
        delete $childs->{$cid};
      });
    });

    $r->websocket('/child' => sub {
      my $self = shift;
      
      $self->on(json => sub {
        my ($tx, $hash) = @_;
        
        # Send message to all childs
        for my $cid (keys %$childs) {
          $childs->{$cid}->send(json => $hash);
        }
      });
    });
  }
  
  # Child
  else {
    # Parent URL
    my $parent_host = $config->{parent}{host};
    croak "[parent]host is empty" unless defined $parent_host;
    
    my $parent_url = "ws://$parent_host";
    my $parent_port = $config->{parent}{port} || '10040';
    $parent_url .= ":$parent_port";

    # Connect to parent
    my $connect_cb;
    $connect_cb = sub {
      my $ua = Mojo::UserAgent->new;
      $ua->websocket($parent_url => sub {
        my ($ua, $tx) = @_;
        
        unless ($tx->is_websocket) {
          my $error = "WebSocket handshake failed!";
          $app->log->error($error);
          Mojo::IOLoop->timer(30 => sub { $connect_cb->() });
          return;
        }
        
        my $local_address = $tx->local_address;
        my $local_port = $tx->local_port;
        
        $tx->on(json => sub {
          my ($tx, $hash) = @_;
          
          my $type = $hash->{type};
          if ($type eq 'task' || $type eq 'sync') {
            my $ua = Mojo::UserAgent->new;
            
            $ua->websocket("ws://$local_address:$local_port/$type" => sub {
              my $self = shift;

              # Receive
              $self->on(json => sub {
                my ($tx, $hash) = @_;
                
                if (my $message = $hash->{message}) {
                  if ($hash->{error}) {
                    $app->log->error("$message");
                  }
                  else {
                    $app->log->info("$message");
                  }
                  $tx->send(json => $hash);
                }
              });
            });
          }
        });
      });
    };
    $connect_cb->();
  }
}

1;
