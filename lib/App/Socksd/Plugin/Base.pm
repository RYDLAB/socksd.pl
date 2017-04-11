package App::Socksd::Plugin::Base;
use Mojo::Base -base;

has 'server';

sub client_accept { 1 }

sub client_connect { (@_[2, 3], 1) }

sub upgrade_sockets {
  shift->server->watch_handles(undef, @_);
}

sub read { $_[2] }

1;
