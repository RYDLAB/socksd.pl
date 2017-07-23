package App::Socksd::Plugin::TLS;
use Mojo::Base 'App::Socksd::Plugin::Base';

use Mojo::IOLoop::TLS;
use IO::Socket::SSL;
use Mojo::IOLoop;

#$IO::Socket::SSL::DEBUG = 3;

sub upgrade_sockets {
  my ($self, $client, $remote, $args, $cb) = @_;

  Mojo::IOLoop->delay(
    sub {
      my $d = shift;
      my $tls_client_args = {server => 1};
      my $tls_remote_args = {server => 0, address => $args->{remote_host}};
      $self->_upgrade_handle($client, $tls_client_args, $d->begin(0));
      $self->_upgrade_handle($remote, $tls_remote_args, $d->begin(0));
    },
    sub {
      my ($d, $err1, $client, $err2, $remote) = @_;
      $cb->($err1 || $err2, $client, $remote);
    }
  );
}

sub _upgrade_handle {
  my ($self, $handle, $args, $cb) = @_;
  my $tls = Mojo::IOLoop::TLS->new($handle);
  $tls->on(upgrade => sub { $cb->(undef, $_[1]) });
  $tls->on(error   => sub { $cb->($_[1], $handle) });
  $tls->negotiate($args);
}

1;
