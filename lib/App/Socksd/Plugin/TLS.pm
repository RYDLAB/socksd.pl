package App::Socksd::Plugin::TLS;
use Mojo::Base 'App::Socksd::Plugin::Base';

use Mojo::IOLoop::TLS;
use IO::Socket::SSL;
use Mojo::IOLoop;

#$IO::Socket::SSL::DEBUG = 3;

sub upgrade_sockets {
  my ($self, $client, $remote, $cb) = @_;

  Mojo::IOLoop->delay(
    sub {
      my $d = shift;
      $self->_upgrade_handle($client, 1, $d->begin(0));
      $self->_upgrade_handle($remote, 0, $d->begin(0));
    },
    sub {
      my ($d, $err1, $client, $err2, $remote) = @_;
      $cb->($err1 || $err2, $client, $remote);
    }
  );
}

sub _upgrade_handle {
  my ($self, $handle, $is_server, $cb) = @_;
  my $tls = Mojo::IOLoop::TLS->new($handle);
  $tls->on(upgrade => sub { $cb->(undef, $_[1]) });
  $tls->on(error   => sub { $cb->($_[1], undef) });
  $tls->negotiate(server => $is_server);
}

1;
