# Build the shared library on Darwin. Sourced by build-bzip2.sh.
# Operates in $src_dir (already cd'd to). Inherits CC, CFLAGS,
# PBS_DEPS, PBS_VER_BZIP2 from the parent script.
#
# Upstream bzip2 has no Mach-O equivalent of Makefile-libbz2_so; drive
# -dynamiclib by hand.

# Compile PIC objects then link a dylib. The objects from the static
# build are not -fPIC by default in bzip2's Makefile, so rebuild them.
src_files="blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c"
for s in $src_files; do
  $CC -fPIC -O2 -c "$s"
done

ver="${PBS_VER_BZIP2}"
major="${ver%%.*}"
rest="${ver#*.}"
minor="${rest%%.*}"

dylib="libbz2.${ver}.dylib"
# Install name is the absolute build-time path so dyld resolves
# against /nix/store/... during subsequent deps' build probes.
# finalize-darwin rewrites to @rpath/<basename> at tarball time.
$CC -dynamiclib -Wl,-install_name,"$PBS_DEPS/lib/$dylib" \
    -compatibility_version "${major}.${minor}" \
    -current_version "$ver" \
    -o "$dylib" \
    blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o

cp "$dylib" "$PBS_DEPS/lib/"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.${major}.${minor}.dylib"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.${major}.dylib"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.dylib"
