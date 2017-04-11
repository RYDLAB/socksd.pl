package App::Socksd::Server;
use Mojo::Base -base;

use Socket qw/getaddrinfo IPPROTO_TCP SOCK_STREAM AI_NUMERICHOST AI_PASSIVE/;
use IO::Socket::IP;
use Mojo::IOLoop;
use Mojo::IOLoop::Client;
use Mojo::Log;
use Scalar::Util 'weaken';
use IO::Socket::Socks qw/:constants $SOCKS_ERROR/;
use Mojo::Loader qw(load_class);

has 'log';
has 'plugin';

sub new {
  my $self = shift->SUPER::new(@_);

  my $log = Mojo::Log->new(level => $self->{config}{log}{level} // 'warn', $self->{config}{log}{path} ? (path => $self->{config}{log}{path}) : ());
  $log->format(sub {
    my ($time, $level, $id) = splice @_, 0, 3;
    return '[' . localtime($time) . '] [' . $level . '] [' . $id . '] ' . join "\n", @_, '';
  });
  $self->{log} = $log;

  $self->{resolve} = $self->{config}{resolve} // 0;

  $self->{local_addrinfo} = {};
  $self->{local_addrinfo_hints}  = {socktype => SOCK_STREAM, protocol => IPPROTO_TCP, flags => ($self->{resolve} ? AI_PASSIVE : AI_NUMERICHOST | AI_PASSIVE)};
  $self->{remote_addrinfo_hints} = {socktype => SOCK_STREAM, protocol => IPPROTO_TCP, flags => ($self->{resolve} ? 0 : AI_NUMERICHOST)};

  if (my $class = $self->{config}{plugin_class}) {
    unshift @INC, $self->{config}{lib_path} if $self->{config}{lib_path};
    # eval {
    #   require App::Socksd::Plugin::Base;
    #   App::Socksd::Plugin::Base->import();
    #   1;
    # };
    die $_ if $_ = load_class $class;
    $self->{plugin} = $class->new(server => $self);
    weaken $self->{plugin}{server};
  }

  return $self;
}

sub start {
  my $self = shift;

  for my $proxy (@{$self->{config}{listen}}) {
    if ($proxy->{bind_source_addr}) {
      my ($err, $addrinfo) = getaddrinfo($proxy->{bind_source_addr}, undef, $self->{local_addrinfo_hints});
      die "getaddrinfo error: $err" if $err;
      $self->{local_addrinfo}{$proxy->{bind_source_addr}} = $addrinfo;
    }

    $self->_listen($proxy);
  }

  return $self;
}

sub run {
  shift->start;
  Mojo::IOLoop->start;
}

sub _listen {
  my ($self, $proxy) = @_;

  my $server = IO::Socket::Socks->new(
    ProxyAddr => $proxy->{proxy_addr}, ProxyPort => $proxy->{proxy_port}, SocksDebug => 0, SocksResolve => $self->{resolve},
    SocksVersion => [4, 5], Listen => SOMAXCONN, ReuseAddr => 1, ReusePort => 1) or die $SOCKS_ERROR;
  push @{$self->{handles}}, $server;
  $server->blocking(0);
  Mojo::IOLoop->singleton->reactor->io($server => sub { $self->_server_accept($server, $proxy->{bind_source_addr}) })->watch($server, 1, 0);
}

sub _server_accept {
  my ($self, $server, $bind_source_addr) = @_;
  return unless my $client = $server->accept;

  my ($time, $rand) = (time(), sprintf('%03d', int rand 1000));
  my $info = {id => "${time}.$$.${rand}", start_time => $time, client_send => 0, remote_send => 0};

  $self->log->debug($info->{id}, 'accept new connection from ' . $client->peerhost);

  my $is_permit = 1;
  $is_permit = $self->plugin->client_accept($client) if $self->plugin;
  unless ($is_permit) {
    $self->log->info($info->{id}, 'block client from ' . $client->peerhost);
    return $client->close;
  }

  $client->blocking(0);
  Mojo::IOLoop->singleton->reactor->io($client, sub {
    my ($reactor, $is_w) = @_;

    my $is_ready = $client->ready();
    return if !$is_ready && ($SOCKS_ERROR == SOCKS_WANT_READ || $SOCKS_ERROR == SOCKS_WANT_WRITE);

    if (!$is_ready) {
      $self->log->warn($info->{id}, 'client connection failed with error: ' . $SOCKS_ERROR);
      $reactor->remove($client);
      return $client->close;
    }

    $reactor->remove($client);

    my ($cmd, $host, $port) = @{$client->command};

    if (!$self->{resolve} && $host =~ m/[^\d.]/) {
      $self->log->warn($info->{id}, 'proxy dns off, see configuration parameter "resolve"');
      return $client->close;
    }

    if ($cmd == CMD_CONNECT) {
      $self->_foreign_connect($info, $bind_source_addr, $client, $host, $port);
    } else {
      $self->log->warn($info->{id}, 'unsupported method, number ' . $cmd);
      $client->close;
    }

  })->watch($client, 1, 1);
}

sub _foreign_connect {
  my ($self, $info, $bind_source_addr, $client, $host, $port) = @_;

  my $is_permit = 1;
  ($host, $port, $is_permit) = $self->plugin->client_connect($client, $host, $port) if $self->plugin;

  unless ($is_permit) {
    $self->log->info($info->{id}, "not allowed client to connect to $host:$port");
    return $client->close;
  }

  my ($err, $peer_addrinfo) = getaddrinfo($host, $port, $self->{remote_addrinfo_hints});
  if ($err) {
    $self->log->warn($info->{id}, 'getaddrinfo error: ' . $err);
    return $client->close;
  }

  my $current_local_addrinfo = $bind_source_addr ? [$self->{local_addrinfo}{$bind_source_addr}] : undef;

  my $handle = IO::Socket::IP->new(Blocking => 0, LocalAddrInfo => $current_local_addrinfo, PeerAddrInfo => [$peer_addrinfo]);

  my $remote_host = Mojo::IOLoop::Client->new;
  $self->{remotes}{client}{$remote_host} = $remote_host;

  $remote_host->on(connect => sub {
    my ($remote_host, $remote_host_handle) = @_;

    delete $self->{remotes}{client}{$remote_host};

    $self->log->debug($info->{id}, 'remote connection established');
    $client->command_reply($client->version == 4 ? REQUEST_GRANTED : REPLY_SUCCESS, $remote_host_handle->sockhost, $remote_host_handle->sockport);

    if ($self->plugin) {
      Mojo::IOLoop->timer(2 => sub { $self->plugin->upgrade_sockets($info, $client, $remote_host_handle) })
    } else {
      $self->watch_handles(undef, $info, $client, $remote_host_handle);
    }
  });

  $remote_host->on(error => sub {
    my ($remote_host, $err) = @_;

    delete $self->{remotes}{client}{$remote_host};

    $self->log->warn($info->{id}, 'connect to remote host failed with error: ' . $err);
    $client->command_reply($client->version == 4 ? REQUEST_FAILED : REPLY_HOST_UNREACHABLE, $host, $port);

    $client->close;
  });

  $remote_host->connect(handle => $handle);
}

sub watch_handles {
  my ($self, $error, $info, $client, $remote) = @_;

  if ($error) {
    $self->log->warn($info->{id}, "upgrade socket failed with error: $error");
    $client->close;
    $remote->close;
    return;
  }

  my $client_stream = Mojo::IOLoop::Stream->new($client);
  my $remote_stream = Mojo::IOLoop::Stream->new($remote);

  $client_stream->timeout(0);
  $remote_stream->timeout(0);

  $self->_io_streams($info, 1, $client_stream, $remote_stream);
  $self->_io_streams($info, 0, $remote_stream, $client_stream);

  $client_stream->start;
  $remote_stream->start;
}

sub _io_streams {
  my ($self, $info, $is_client, $stream1, $stream2) = @_;

  $stream1->on('close' => sub {
    my $message = sprintf('%s close connection; duration %ss; bytes send %s',
        ($is_client ? 'client' : 'remote host'), time() - $info->{start_time},
        ($is_client ? $info->{client_send} : $info->{remote_send}));
    $self->log->debug($info->{id}, $message);
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('error' => sub {
    my ($stream, $err) = @_;
    $self->log->warn($info->{id}, 'remote connection failed with error: ' . $err);
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('read' => sub {
    my ($stream, $bytes) = @_;
    $bytes = $self->plugin->read($stream1->handle, $bytes) if $self->plugin;
    $is_client ? $info->{client_send} += length($bytes) : $info->{remote_send} += length($bytes);
    $stream2->write($bytes);
  });
}

1;
