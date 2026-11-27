# ssh2 — PECL extension binding libssh2 to PHP: ssh2_connect / ssh2_exec /
# ssh2_scp_*, plus the ssh2.sftp:// and ssh2.shell:// stream wrappers.
# Built via the just-installed bin/phpize, mirroring imagick.nix.
#
# Depends on `php` (phpize/php-config/build files) and `libssh2`. openssl
# and zlib arrive transitively through libssh2's own RPATH; ssh2.so itself
# references only libssh2 symbols, so they are not direct inputs here.
#
# `ssh2Spec` is the value from sources.ssh2Versions.<series>.
{ mkDep, pkgs, php, libssh2, ssh2Spec }:
mkDep {
  name = "ssh2";
  buildScript = ./build-ssh2.sh;
  version = ssh2Spec.version;
  src = pkgs.fetchurl { inherit (ssh2Spec) url sha256; };
  deps = [ php libssh2 ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
