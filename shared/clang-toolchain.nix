# Clang-based toolchain that targets our old-glibc sysroot.
#
# Composition: nixpkgs's modern clang (unwrapped) + our CentOS 7 sysroot
# from sysroot.nix. The output is a single derivation that ships:
#   $out/bin/cc       — clang wrapped with --sysroot, --target, etc.
#   $out/bin/c++      — clang++ similarly wrapped
#   $out/bin/ld       — lld wrapped to target the sysroot
#   $out/bin/ar, $out/bin/strip, ...  — symlinks to llvm tools
#   $out/lib/libstdc++.a  — copy of the devtoolset-11 static archive
#                           (resolved at link time so the path stays stable)
#
# Why unwrapped clang: nixpkgs's normal `clang` is wrapped with cc-wrapper
# that injects -isystem, -L, -rpath flags pointing at *nixpkgs's* glibc
# and gcc. That defeats the entire point of our sysroot. unwrapped clang
# is the raw binary; we add only the flags we want.
{ stdenvNoCC
, lib
, llvmPackages_18
, bash
, sysroot
}:
let
  llvm = llvmPackages_18;
  clang = llvm.clang-unwrapped;
  # clang ships its compiler-internal headers (stdarg.h, stddef.h, the
  # Intel intrinsics, etc.) in a separate -lib output to keep the main
  # bin output small. We need both.
  clangLib = llvm.clang-unwrapped.lib;
  lld = llvm.lld;
  llvmTools = llvm.llvm;

  # clang resource dir = clang's own internal headers + builtins library.
  # Path layout is `lib/clang/<major>/include` and `lib/clang/<major>/lib`.
  clangResourceDir = "${clangLib}/lib/clang/${lib.versions.major llvm.release_version}";

  # Relevant directories inside the sysroot.
  sysIncludeCxx = "${sysroot}/usr/include/c++/11";
  sysIncludeCxxArch = "${sysIncludeCxx}/x86_64-redhat-linux";

  # Common flags every cc invocation needs. clang's --sysroot handles most
  # of the C side automatically; the C++ side needs explicit -isystem for
  # libstdc++ headers (those don't live under standard sysroot paths,
  # they live under devtoolset's /opt/rh/... which we copied in).
  commonFlags = lib.concatStringsSep " " [
    "--target=x86_64-unknown-linux-gnu"
    "--sysroot=${sysroot}"
    # Explicit linker — point at the lld absolute path so we don't depend
    # on PATH or clang's default ld-search heuristics.
    "--ld-path=${lld}/bin/ld.lld"
    # -B controls clang's startup-file (crt1, crtbeginS, ...) and
    # auxiliary-program search path. Pointing it at the sysroot's lib64
    # is what makes clang find devtoolset-11's crt files instead of
    # falling back to "look in gcc's install dir we don't have".
    "-B${sysroot}/usr/lib64"
    # -L for the linker — finds -lc, -lgcc, -lpthread, etc.
    "-L${sysroot}/usr/lib64"
    # Use libgcc (devtoolset-11's, in the sysroot) for runtime helpers.
    # Compiler-rt would also work but mixing it with libstdc++'s C++
    # unwinder is finicky; libgcc + libstdc++ from the same gcc 11 is
    # the matched pair.
    "-rtlib=libgcc"
    # Static-link libgcc + libgcc_eh — devtoolset-11's archives in the
    # sysroot. Avoids needing libgcc_s.so.1 at runtime, which our
    # consumer host wouldn't necessarily have at the right version.
    "-static-libgcc"
    # Bake the SYSROOT's glibc-2.17 dynamic linker into .interp at link
    # time. Two reasons we don't use /lib64/ld-linux-x86-64.so.2 directly:
    #
    #  (1) That path doesn't exist inside the Nix build sandbox. Many
    #      autoconf-style builds (nghttp2, freetype, ...) compile a tiny
    #      C program and *run* it as part of feature detection
    #      ("cannot run C compiled programs") — those would all fail.
    #  (2) Clang's Linux driver normally derives the interp from a
    #      gcc-install-dir, which we don't have, so it would otherwise
    #      omit the interp entirely.
    #
    # finalize.sh rewrites every dynamically-linked executable's .interp
    # back to /lib64/ld-linux-x86-64.so.2 (the LSB-standard path that
    # every mainstream glibc distro provides) before tarballing. So the
    # consumer-visible value is unaffected.
    "-Wl,-dynamic-linker,${sysroot}/lib64/ld-linux-x86-64.so.2"
    # Bake an RPATH pointing at the sysroot's runtime libs so that any
    # binary the build spawns mid-build (autoconf's conftest, configure
    # probes, in-tree tests) can resolve libc.so.6 / libpthread.so.0 /
    # libm.so.6 against our glibc-2.17. Using DT_RPATH instead of
    # LD_LIBRARY_PATH keeps the override process-local — it doesn't
    # bleed into bash / make / awk / etc., which are linked against
    # modern glibc and would crash on our libc-2.17.
    # finalize.sh's `patchelf --remove-rpath` clears these entries, then
    # `--force-rpath --set-rpath '$ORIGIN/../lib'` writes the consumer-
    # facing value, so the sysroot path never reaches the tarball.
    "-Wl,-rpath,${sysroot}/lib64"
    "-Wl,-rpath,${sysroot}/usr/lib64"
    # lld 13+ rejects version scripts that name symbols not defined in the
    # link unit (GNU ld silently allows it). zlib's configure builds a
    # tiny probe object linked against zlib.map, which references all the
    # public zlib symbols — only `hello` is defined → lld errors → zlib
    # falls back to static. --undefined-version restores GNU-ld leniency.
    "-Wl,--undefined-version"
    # Suppress "argument unused" warnings for flags that only apply to a
    # subset of invocations (e.g. -static-libgcc on a compile-only call).
    "-Wno-unused-command-line-argument"
    # Pin the resource dir so clang reliably finds its own internal
    # headers (stdarg.h, stddef.h, *intrin.h, ...) and compiler-rt libs.
    "-resource-dir=${clangResourceDir}"
    # -nostdinc suppresses *both* clang's default includes AND the host
    # /usr/include search. That's defense-in-depth — without it, clang
    # would silently #include from /usr/include if anything else slipped
    # through. We then opt the system headers back in via -isystem,
    # explicitly targeting our sysroot's tree.
    "-nostdinc"
    "-isystem ${clangResourceDir}/include"
  ];

  # C system headers, threaded into the search list AFTER any C++ ones
  # so that libstdc++'s `#include_next <stdlib.h>` style chains resolve.
  # For pure-C compiles (cc) this gets used unchanged; for C++ (c++) it
  # appears after the C++ paths.
  cIncludesFlag = "-isystem ${sysroot}/usr/include";

  cxxFlags = lib.concatStringsSep " " [
    "-stdlib=libstdc++"
    # -nostdinc++ stops clang from auto-injecting any C++ include paths
    # it derived from a (nonexistent) gcc detection. We then specify the
    # libstdc++ headers explicitly so they come *before* the C headers
    # in the search order — required so cstdlib's `#include_next
    # <stdlib.h>` can reach the glibc one.
    "-nostdinc++"
    "-isystem ${sysIncludeCxx}"
    "-isystem ${sysIncludeCxxArch}"
    "-isystem ${sysIncludeCxx}/backward"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "pbs-toolchain";
  version = "clang-${llvm.release_version}-glibc-2.17";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p $out/bin $out/lib

    # Wrap clang as our `cc`. Inject our flags as a fixed prefix on every
    # invocation. The `exec` form ensures signal forwarding works.
    #
    # For C++ we put the libstdc++ -isystem flags BEFORE the C headers
    # one — necessary so `#include_next <stdlib.h>` from libstdc++'s
    # cstdlib finds the glibc stdlib.h. For C, no C++ paths involved.
    cat > $out/bin/cc <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang ${commonFlags} ${cIncludesFlag} "\$@"
    EOF

    cat > $out/bin/c++ <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang++ ${commonFlags} ${cxxFlags} ${cIncludesFlag} "\$@"
    EOF

    chmod +x $out/bin/cc $out/bin/c++

    # The libstdc++.a we want as a positional LDFLAG when statically
    # linking C++ into PHP. Expose it at a well-known path.
    ln -s ${sysroot}/usr/lib64/libstdc++.a $out/lib/libstdc++.a

    # Other binutils-equivalents the build scripts might invoke directly.
    # Use llvm versions: ld.lld, llvm-ar, llvm-nm, llvm-strip,
    # llvm-objdump, llvm-ranlib, llvm-objcopy.
    ln -s ${lld}/bin/ld.lld $out/bin/ld
    ln -s ${lld}/bin/lld $out/bin/lld
    for t in ar nm strip objdump ranlib objcopy readelf; do
      ln -s ${llvmTools}/bin/llvm-$t $out/bin/$t
    done

    runHook postBuild
  '';

  dontInstall = true;
  dontFixup = true;

  passthru = {
    inherit sysroot clang lld llvmTools;
  };
}
