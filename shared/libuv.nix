# libuv bundled-dep derivation. Cross-platform asynchronous I/O library
# (the event loop underneath Node.js); consumed by the `uv` PECL
# extension, which backs ReactPHP's ExtUvLoop.
#
# Self-contained — no bundled-dep inputs. On Linux it needs only pthreads
# and librt from the sysroot; on Darwin it links the CoreFoundation /
# CoreServices frameworks, which its CMakeLists wires up itself.
#
# cmake rather than mkDep's autotools template: the dist tarball ships
# CMakeLists.txt and autogen.sh but no pre-generated `configure`, and
# running autogen.sh would add an autoreconf pass for no gain.
{ mkDep }:
mkDep {
  name = "libuv";
}
