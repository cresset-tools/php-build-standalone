# NSS (Network Security Services) bundled-dep derivation. Depends on
# NSPR (the runtime layer), our sqlite (cert9.db backend), and zlib.
#
# NSS uses a hand-rolled gmake build instead of autotools — see
# build-nss.sh for the wiring. The output is normalized into the same
# `bin/`, `lib/`, `include/<name>/` layout the rest of PBS uses, so
# downstream consumers (mkcert tarball) can patchelf RPATHs and ship
# the result without knowing NSS's quirks.
{ mkDep, pkgs, nspr, sqlite, zlib }:
mkDep {
  name = "nss";
  deps = [ nspr sqlite zlib ];
  # NSS's build needs Python (for some code generators) and Perl (for
  # configuration scripts). gmake aliasing happens inside build-nss.sh.
  extraInputs = with pkgs; [ python3 perl ];
}
