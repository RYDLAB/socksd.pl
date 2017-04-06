use Mojo::Base -strict;

use Test::More;
use Mojo::IOLoop;
use App::Socksd::Server;

my $proxy = App::Socksd::Server->new(config => {
  listen => [{proxy_addr => '127.0.0.1', bind_source_addr => '127.0.0.2'}]
})->start;

my $socks_port = $proxy->{handles}[0]->sockport;

my $s_id = Mojo::IOLoop->server({address => '127.0.0.1'} => sub {
  my ($loop, $stream) = @_;

  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    is $stream->handle->peerhost, '127.0.0.2';
    is $bytes, 'PING';
    $stream->write("PONG");
  });
});

my $server_port = Mojo::IOLoop->acceptor($s_id)->port;

Mojo::IOLoop->client({socks_address => '127.0.0.1', socks_port => $socks_port, address => '127.0.0.1', port => $server_port} => sub {
  my ($loop, $err, $stream) = @_;

  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    is $bytes, 'PONG';
    Mojo::IOLoop->stop;
  });

  $stream->write("PING");
});

Mojo::IOLoop->start;

done_testing;
