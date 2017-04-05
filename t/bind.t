use Mojo::Base -strict;

use Test::More;
use Mojo::IOLoop;
use App::Socksd::Server;

my $proxy = App::Socksd::Server->new(config => {
  listen => [{proxy_addr => '127.0.0.1', proxy_port => 12345, bind_source_addr => '127.0.0.2'}]
})->start;

Mojo::IOLoop->server({port => 54321} => sub {
  my ($loop, $stream) = @_;

  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    is $stream->handle->peerhost, '127.0.0.2';
    is $bytes, 'PING';
    $stream->write("PONG");
  });
});

Mojo::IOLoop->client({socks_address => '127.0.0.1', socks_port => 12345, address => '127.0.0.1', port => 54321} => sub {
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
