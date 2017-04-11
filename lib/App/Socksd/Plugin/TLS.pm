package App::Socksd::Plugin::TLS;
use Mojo::Base 'App::Socksd::Plugin::Base';

use Mojo::IOLoop::TLS;

sub upgrade_sockets {
  shift->_upgrade_client(@_)
}

sub _upgrade_client {
  my ($self, $info, $client, $remote) = @_;
  my $tls_client = Mojo::IOLoop::TLS->new($client);
  $tls_client->on(upgrade => sub { $self->_upgrade_remote($info, pop(), $remote) });
  $tls_client->on(error   => sub { warn 111; $self->server->watch_handles(pop(), $info, $client, $remote) });
  $tls_client->negotiate(server => 1, tls_cert => '/home/logioniz/cert/cert.pem', tls_key => '/home/logioniz/cert/key.pem');
}

sub _upgrade_remote {
  my ($self, $info, $client, $remote) = @_;
  my $tls_remote = Mojo::IOLoop::TLS->new($remote);
  $tls_remote->on(upgrade => sub { $self->server->watch_handles(undef, $info, $client, pop()) });
  $tls_remote->on(error   => sub { warn 222; $self->server->watch_handles(pop(), $info, $client, $remote) });
  $tls_remote->negotiate;
}

1;
