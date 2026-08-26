# libevent bundled-dep derivation. Event-notification library (epoll on
# Linux, kqueue on Darwin); consumed by the `event` PECL extension, which
# backs ReactPHP's ExtEventLoop.
#
# Depends on openssl so libevent_openssl.so is built — `event` links it
# unconditionally under its default --with-event-openssl=yes, and that's
# what makes EventSslContext / EventBufferEvent::sslSocket() work. The
# extension also links event_core (the loop itself) and event_extra
# (DNS / HTTP / RPC / listener).
#
# Autotools template applies: the release tarball ships a pre-generated
# `configure`, so there's no autogen.sh step to script around.
{ mkDep, openssl }:
mkDep {
  name = "libevent";
  builder = "autotools";
  # Upstream names the tarball (and its extract dir) with a `-stable`
  # suffix that our `version` drops — see sources.nix for why.
  srcSubdir = v: "libevent-${v}-stable";
  deps = [ openssl ];
  # libevent's configure prefers pkg-config for OpenSSL and only falls
  # back to a header/lib probe. mkDep already appends -I/-L for every dep
  # to CPPFLAGS/LDFLAGS, so the fallback would work — but pointing
  # PKG_CONFIG_PATH at the bundled prefix keeps it on the same code path
  # every other openssl consumer here takes, and stops it from finding a
  # host openssl.pc first.
  extraEnv.PKG_CONFIG_PATH = "$PBS_DEP_OPENSSL/lib/pkgconfig";
  configureFlags = [
    # The sample programs and the regress suite build test binaries that
    # link the just-built libs and bake the build dir into their RPATHs.
    # Nothing downstream needs either.
    "--disable-samples"
    "--disable-libevent-regress"
  ];
  # event_rpcgen.py — a code generator for libevent's RPC layer, useful
  # only when compiling C against libevent. `event` doesn't invoke it.
  postInstallCleanup = [ "bin" ];
  # The four modular libraries. The deprecated all-in-one libevent.so is
  # also installed and rides along unaudited — nothing links it, and
  # dropping it would diverge from what every distro ships.
  auditLibs = [
    "libevent_core"
    "libevent_extra"
    "libevent_openssl"
    "libevent_pthreads"
  ];
}
