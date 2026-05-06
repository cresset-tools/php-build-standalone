# Build the shared library on Linux. Sourced by build-bzip2.sh.
# Operates in $src_dir (already cd'd to). Inherits CC, CFLAGS,
# PBS_DEPS, PBS_VER_BZIP2 from the parent script.
#
# bzip2 ships Makefile-libbz2_so which knows how to produce a Linux
# ELF .so but has no install target.

make -f Makefile-libbz2_so CC="$CC" CFLAGS="$CFLAGS"

cp libbz2.so.1.0.8 "$PBS_DEPS/lib/"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so.1.0"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so.1"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so"
