# musl (x86_64-unknown-linux-musl) toolchain wrapper.
#
# Same shape as clang-toolchain.nix (the glibc leg): nixpkgs's modern
# *glibc-hosted* clang (unwrapped) re-pointed at a musl sysroot via
# --target + explicit -B/-L/-isystem. The compiler runs on the glibc build
# host and merely *targets* musl — so we reuse the already-cached clang-18
# from nixpkgs rather than pkgsMusl's clang (which would mean compiling all
# of LLVM against musl: hours, uncached).
#
# The musl sysroot is nixpkgs's `pkgsMusl.musl` package (libc + headers +
# crt files + the ld-musl dynamic linker), passed in as muslOut/muslDev.
# That's the "use nixpkgs pkgsMusl" decision: musl itself comes from
# nixpkgs (cached), not from source or Alpine.
#
# Why dynamic (not static): a fully static PHP gives up dlopen, hence
# loadable extension `.so`s — and bougie's whole model is per-extension
# tarballs. So we link shared against system musl, like
# python-build-standalone's post-20250311 builds. finalize-linux.sh
# rewrites the interpreter to /lib/ld-musl-x86_64.so.1 and RPATHs to the
# relocatable $ORIGIN form.
#
# C++ (libc++) for the C++ deps (ICU/intl, ImageMagick, libheif) is wired
# in a follow-up: the cxx wrapper below selects -stdlib=libc++ but the
# libc++ search paths are still TODO, so C-only deps build today.
{ stdenvNoCC
, lib
, llvmPackages_18
, bash
, muslOut
, muslDev
, cxxGcc        # pkgsMusl gcc (out): musl-targeted libstdc++ headers + .a
, cxxGccLib     # pkgsMusl gcc (lib): libstdc++.so.6
}:
let
  llvm = llvmPackages_18;
  clang = llvm.clang-unwrapped;
  clangLib = llvm.clang-unwrapped.lib;
  lld = llvm.lld;
  llvmTools = llvm.llvm;

  clangResourceDir = "${clangLib}/lib/clang/${lib.versions.major llvm.release_version}";

  # pkgsMusl gcc's libgcc.a / libgcc_eh.a (the matched runtime + unwinder
  # for its libstdc++). Same role as devtoolset's libgcc on the glibc leg.
  gccLibgccDir = "${cxxGcc}/lib/gcc/x86_64-unknown-linux-musl/${cxxGcc.version}";

  commonFlags = lib.concatStringsSep " " [
    "--target=x86_64-unknown-linux-musl"
    "--ld-path=${lld}/bin/ld.lld"
    # Pin clang to pkgsMusl's gcc install (its crt*.o, libgcc, libstdc++)
    # so it does NOT auto-detect the build host's glibc gcc — otherwise
    # -static-libstdc++ pulls the host /usr/lib/gcc glibc libstdc++.a and
    # the link dies on glibc-only symbols (__isoc23_strtoul, fseeko64, …).
    "--gcc-install-dir=${gccLibgccDir}"
    # crt1.o / crti.o / crtn.o + libc live in pkgsMusl.musl's lib/; gcc's
    # crtbegin.o / crtend.o live in the gcc install dir. Both on the -B
    # startup-file search path.
    "-B${muslOut}/lib"
    "-B${gccLibgccDir}"
    "-L${muslOut}/lib"
    # Runtime helpers (__divti3, …) + the C++ unwinder come from pkgsMusl
    # gcc's libgcc, statically linked — exactly the glibc leg's approach
    # (-rtlib=libgcc -static-libgcc). compiler-rt would also provide the
    # builtins but not the _Unwind_* symbols libstdc++ exceptions need, and
    # static libgcc avoids a runtime libgcc_s.so.1 dependency on our own
    # binaries.
    "-L${gccLibgccDir}"
    "-rtlib=libgcc"
    "-static-libgcc"
    # Bake the musl dynamic linker into .interp at link time. The path
    # exists in the sandbox (unlike /lib/ld-musl-…), so autoconf conftests
    # that compile-and-run during configure work. finalize-linux.sh
    # rewrites .interp to the consumer-standard /lib/ld-musl-x86_64.so.1.
    "-Wl,-dynamic-linker,${muslOut}/lib/ld-musl-x86_64.so.1"
    # RPATH so in-build conftests resolve libc against our musl. finalize
    # strips these and writes the $ORIGIN-relative consumer RPATH.
    "-Wl,-rpath,${muslOut}/lib"
    # lld rejects version scripts naming undefined symbols (zlib's probe);
    # restore GNU-ld leniency (same as the glibc leg).
    "-Wl,--undefined-version"
    "-Wno-unused-command-line-argument"
    # glibc auto-defines __STDC_ISO_10646__ (via stdc-predef.h); musl does
    # not, even though its wchar_t is 32-bit ISO 10646. Some deps guard on
    # it (libedit's chartype.h, ncurses widec) and #error out without it.
    # Define it here to mirror glibc — correct for musl's wchar_t.
    "-D__STDC_ISO_10646__=201706L"
    # Pin clang's own internal headers (stddef.h, stdarg.h, *intrin.h …).
    "-resource-dir=${clangResourceDir}"
    # libstdc++ search paths live in commonFlags (not just the c++ wrapper)
    # because build systems append `-lstdc++` to plain `cc` link lines too
    # (PHP's configure does this on its conftests). libstdc++.a is in gcc's
    # `out`, libstdc++.so.6 in gcc's `lib`. The glibc leg gets this for free
    # via its sysroot lib64 -L. rpath lets dynamic C++ conftests run.
    "-L${cxxGcc}/lib"
    "-L${cxxGccLib}/lib"
    "-Wl,-rpath,${cxxGccLib}/lib"
    # Suppress clang's default + host /usr/include search; opt the musl
    # sysroot headers back in explicitly.
    "-nostdinc"
    "-isystem ${clangResourceDir}/include"
  ];

  cIncludesFlag = "-isystem ${muslDev}/include";

  # C++ runtime: pair clang with libstdc++ from pkgsMusl's gcc — the same
  # shape as the glibc leg (clang + devtoolset libstdc++), just sourced from
  # nixpkgs's musl gcc instead. libc++ via pkgsMusl.llvmPackages would force
  # building LLVM from source (uncached, hours); pkgsMusl's gcc/libstdc++ is
  # cached. Headers go BEFORE the C headers (cIncludesFlag) in the wrapper so
  # libstdc++'s `#include_next <stdlib.h>` chains reach musl's stdlib.h.
  cxxIncludeBase = "${cxxGcc}/include/c++/${cxxGcc.version}";
  cxxIncludeArch = "${cxxIncludeBase}/x86_64-unknown-linux-musl";
  cxxFlags = lib.concatStringsSep " " [
    "-stdlib=libstdc++"
    "-nostdinc++"
    "-isystem ${cxxIncludeBase}"
    "-isystem ${cxxIncludeArch}"
    "-isystem ${cxxIncludeBase}/backward"
    # (libstdc++ -L/-rpath moved to commonFlags — see there.)
  ];
in
stdenvNoCC.mkDerivation {
  pname = "pbs-toolchain-musl";
  version = "clang-${llvm.release_version}-musl-1.2.5";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p $out/bin

    cat > $out/bin/cc <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang ${commonFlags} ${cIncludesFlag} "\$@"
    EOF

    cat > $out/bin/c++ <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang++ ${commonFlags} ${cxxFlags} ${cIncludesFlag} "\$@"
    EOF

    chmod +x $out/bin/cc $out/bin/c++

    # Expose libstdc++.a at a stable path for build-php-pre-configure-musl.sh
    # (the positional static-libstdc++ link into bin/php), mirroring the
    # glibc toolchain's $out/lib/libstdc++.a.
    mkdir -p $out/lib
    ln -s ${cxxGcc}/lib/libstdc++.a $out/lib/libstdc++.a

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
    inherit clang lld llvmTools muslOut muslDev;
    # The musl leg has no glibc-style sysroot; mkDep skips PBS_SYSROOT.
    sysroot = null;
  };
}
