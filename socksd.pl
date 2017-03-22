#!/usr/bin/perl
use Mojo::Base -strict;

use Socket;
use Mojo::IOLoop;
use Mojo::Log;
use IO::Socket::Socks qw/:constants $SOCKS_ERROR/;

# Config
my $config = do 'socksd.conf';
die "Invalid config file: $@\n"    if $@;
die "Can't read config file: $!\n" if $!;

my $log = Mojo::Log->new(level => $config->{log}{level} // 'warn', $config->{log}{path} ? (path => $config->{log}{path}) : ());
$log->format(sub {
  my ($time, $level, $id) = splice @_, 0, 3;
  return '[' . localtime($time) . '] [' . $level . '] [' . $id . '] ' . join "\n", @_, '';
});

for my $proxy (@{$config->{listen}}) {
  my $server = IO::Socket::Socks->new(
    ProxyAddr => $proxy->{proxy_addr}, ProxyPort => $proxy->{proxy_port}, SocksDebug => 0,
    SocksVersion => [4, 5], Listen => SOMAXCONN, ReuseAddr => 1, ReusePort => 1) or die $SOCKS_ERROR;
  $server->blocking(0);
  Mojo::IOLoop->singleton->reactor->io($server => sub { &server_accept($server, $proxy->{bind_source_addr}) })->watch($server, 1, 0);
}

Mojo::IOLoop->start;

sub server_accept {
  my ($server, $bind_source_addr) = @_;
  return unless my $client = $server->accept;

  my ($time, $rand) = (time(), sprintf('%03d', int rand 1000));
  my $info = {id => "${time}.$$.${rand}", start_time => $time};

  $log->debug($info->{id}, 'accept new connection from ' . $client->peerhost);

  $client->blocking(0);
  Mojo::IOLoop->singleton->reactor->io($client, sub {
    my ($reactor, $is_w) = @_;

    my $is_ready = $client->ready();
    return if !$is_ready && ($SOCKS_ERROR == SOCKS_WANT_READ || $SOCKS_ERROR == SOCKS_WANT_WRITE);

    if (!$is_ready) {
      $log->warn($info->{id}, 'client connection failed with error: ' . $SOCKS_ERROR);
      $reactor->remove($client);
      return $client->close;
    }

    $reactor->remove($client);

    my ($cmd, $host, $port) = @{$client->command};

    if ($cmd == CMD_CONNECT) {
      &foreign_connect($info, $bind_source_addr, $client, $host, $port);
    } else {
      $log->warn($info->{id}, 'unsupported method, number ' . $cmd);
      $client->close;
    }

  })->watch($client, 1, 1);
}

sub foreign_connect {
  my ($info, $bind_source_addr, $client, $host, $port) = @_;

  my $id = Mojo::IOLoop->client(address => $host, port => $port, local_address => $bind_source_addr => sub {
    my ($loop, $err, $foreign_stream) = @_;

    if ($err) {
      $log->warn($info->{id}, 'remote connection failed with error: ' . $err);
      $client->command_reply($client->version == 4 ? REQUEST_FAILED : REPLY_HOST_UNREACHABLE, $host, $port);
      $client->close();
      return;
    }

    $log->debug($info->{id}, 'remote connection established');
    $client->command_reply($client->version == 4 ? REQUEST_GRANTED : REPLY_SUCCESS, $foreign_stream->handle->sockhost, $foreign_stream->handle->sockport);

    my $client_stream = Mojo::IOLoop::Stream->new($client);

    &io_streams($info, 1, $client_stream, $foreign_stream);
    &io_streams($info, 0, $foreign_stream, $client_stream);

    $client_stream->start;
  });
}

sub io_streams {
  my ($info, $is_client, $stream1, $stream2) = @_;

  $stream1->on('close' => sub {
    my $message = sprintf('%s close connection; duration %ss', ($is_client ? 'client' : 'remote host'), time() - $info->{start_time});
    $log->debug($info->{id}, $message);
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('error' => sub {
    my ($stream, $err) = @_;
    $log->warn($info->{id}, 'remote connection failed with error: ' . $err);
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('read' => sub {
    my ($stream, $bytes) = @_;
    $stream2->write($bytes);
  });
}
