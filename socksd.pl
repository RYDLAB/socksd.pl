#!/usr/bin/perl
use Mojo::Base -strict;

use Socket;
use Mojo::IOLoop;
use IO::Socket::Socks qw/:constants $SOCKS_ERROR/;

my @configs = ({
    proxy_addr        => '127.0.0.1',
    proxy_port        => 12345,
    bind_source_addr  => '192.168.0.60'
  }, {
    proxy_addr        => '127.0.0.1',
    proxy_port        => 12346,
    bind_source_addr  => '192.168.88.253'
  }
);

for my $config (@configs) {
  my $server = IO::Socket::Socks->new(
    ProxyAddr => $config->{proxy_addr}, ProxyPort => $config->{proxy_port}, Blocking => 0, SocksDebug => 0,
    SocksVersion => [4, 5], Listen => SOMAXCONN, ReuseAddr => 1, ReusePort => 1) or die $SOCKS_ERROR;
  Mojo::IOLoop->singleton->reactor->io($server => sub { &server_accept($server, $config->{bind_source_addr}) })->watch($server, 1, 0);
}

Mojo::IOLoop->start;

#$server->close();

sub server_accept {
  my ($server, $bind_source_addr) = @_;
  return unless my $client = $server->accept;

  $client->blocking(0);
  Mojo::IOLoop->singleton->reactor->io($client, sub {
    my ($reactor, $is_w) = @_;
    return unless $client->ready();

    $reactor->remove($client);

    my ($cmd, $host, $port) = @{$client->command};

    if ($cmd == CMD_CONNECT) {
      &foreign_connect($bind_source_addr, $client, $host, $port);
    } else {
      warn 'UNSUPPORTED METHOD';
    }

  })->watch($client, 1, 0);
}

sub foreign_connect {
  my ($bind_source_addr, $client, $host, $port) = @_;

  my $id = Mojo::IOLoop->client(address => $host, port => $port, local_address => $bind_source_addr => sub {
    my ($loop, $err, $foreign_stream) = @_;

    if ($err) {
      $client->command_reply($client->version == 4 ? REQUEST_FAILED : REPLY_HOST_UNREACHABLE, $host, $port);
      $client->close();
      return;
    }

    $client->command_reply($client->version == 4 ? REQUEST_GRANTED : REPLY_SUCCESS, $foreign_stream->handle->sockhost, $foreign_stream->handle->sockport);

    my $client_stream = Mojo::IOLoop::Stream->new($client);

    &io_streams($client_stream, $foreign_stream);
    &io_streams($foreign_stream, $client_stream);

    $client_stream->start;
  });
}

sub io_streams {
  my ($stream1, $stream2) = @_;

  $stream1->on('close' => sub {
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('error' => sub {
    $stream2->close;
    undef $stream2;
  });

  $stream1->on('read' => sub {
    my ($stream, $bytes) = @_;
    $stream2->write($bytes);
  });
}
