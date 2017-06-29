package App::Socksd::Plugin::Base;
use Mojo::Base -base;

sub client_accept { 1 }

sub client_connect { (@_[2, 3], 1) }

sub upgrade_sockets {
  pop()->(undef, @_[1, 2]);
}

sub read { $_[2] }

1;
