# mkcert binary derivation. mkcert is a small Go program (FiloSottile/mkcert)
# that generates locally-trusted CAs and certificates for development.
# Built with CGO_ENABLED=0 so the resulting binary is a fully static Go
# executable — no glibc-version baseline, no shared-lib runtime deps.
#
# The Firefox-trust path mkcert exposes via `mkcert -install` shells out
# to `certutil` (the NSS CLI) as a subprocess; we ship that alongside
# mkcert from `shared/nss.nix`. The PATH wiring happens at tarball
# assembly time in `tarball.nix` — this derivation only produces the
# mkcert binary itself.
{ pkgs, sources }:
let
  mkcertSpec = sources.mkcert;
in
pkgs.buildGoModule {
  pname = "mkcert";
  version = mkcertSpec.version;
  src = pkgs.fetchurl {
    inherit (mkcertSpec) url sha256;
  };
  # Computed by Nix on first build — `lib.fakeHash` triggers a build
  # failure that prints the actual hash, which we pin here. Bumping
  # mkcert's version requires recomputing this; the failure mode is
  # loud + obvious, so no risk of silent staleness.
  vendorHash = "sha256-DdA7s+N5S1ivwUgZ+M2W/HCp/7neeoqRQL0umn3m6Do=";
  doCheck = false;  # mkcert's own tests require an interactive setup
  # CGO_ENABLED=0 → fully static Go binary, no glibc dep.
  env.CGO_ENABLED = "0";
  # Bake the version into `mkcert -version`; matches upstream's
  # release-artifact `ldflags`.
  ldflags = [
    "-X" "main.Version=v${mkcertSpec.version}"
    "-s" "-w"  # strip; smaller binary
  ];
}
