# Perl socks (socks4 and socks5) proxy server with plugins

Socks proxy server with ability to make static auth check (in config file) or dynamic auth check (via plugins).

It is also possible to do a MITM attack to view traffic:
1. for plain traffic (without tls)
  It is necessary to take as a basis a plug-in "Base"
2. for tls traffic
  It is necessary to take as a basis a plug-in "TLS"

## Installation

On Debian based distributions
```
sudo apt-get install git cpanminus
git clone https://github.com/RYDLAB/socksd.pl.git
cd socksd.pl/
sudo cpanm --installdeps .
perl -I lib/ script/socksd.pl
```
