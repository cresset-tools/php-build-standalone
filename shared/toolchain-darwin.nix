# Darwin (aarch64-apple-darwin) toolchain wrapper.
#
# Unlike the Linux side, macOS portability does NOT come from a custom
# old-libc sysroot. The portable surface is:
#
#   - MACOSX_DEPLOYMENT_TARGET=11.0 (Big Sur) — same floor PBS targets.
#     Sets the LC_BUILD_VERSION minos field; macOS refuses to load Mach-Os
#     whose minos exceeds the running kernel.
#   - System libc (libSystem.B.dylib at /usr/lib/libSystem.B.dylib) is
#     ABI-stable; we link against the SDK's tbd stubs and at runtime the
#     consumer's /usr/lib resolves DT-equivalent dyld load commands.
#   - System libc++ is ABI-stable; we use it (no libstdc++ on macOS).
#
# So this wrapper is much thinner than clang-toolchain.nix on Linux:
# we accept nixpkgs's default clang (it already knows how to find the
# Apple SDK at /Applications/Xcode.app or via apple-sdk_11) and add
# only the deployment-target + headerpad flags.
#
# `-Wl,-headerpad_max_install_names` is load-bearing: install_name_tool
# can only rewrite an LC_LOAD_DYLIB entry to a longer path if the Mach-O
# header has spare bytes reserved for it. Default ld64 padding is too
# small for `@rpath/...` rewrites in some cases, and the build fails
# with "changing install names or rpaths can't be redone for: ...
# (the program must be relinked, and you may need to use the
# -headerpad_max_install_names option)". PBS uses `-headerpad,40`;
# we use the more generous `_max_install_names` form.
{ stdenvNoCC
, lib
, clang
, llvmPackages
, cctools
, bash
}:
let
  # Use nixpkgs's wrapped clang. On aarch64-darwin it already knows the
  # SDK path via the cc-wrapper's NIX_CFLAGS_COMPILE / framework dirs.
  llvmTools = llvmPackages.llvm;

  deploymentTarget = "11.0";

  commonCflags = lib.concatStringsSep " " [
    "-mmacosx-version-min=${deploymentTarget}"
    "-arch arm64"
  ];

  commonLdflags = lib.concatStringsSep " " [
    "-mmacosx-version-min=${deploymentTarget}"
    "-arch arm64"
    "-Wl,-headerpad_max_install_names"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "pbs-toolchain-darwin";
  version = "clang-${clang.version or "unknown"}-macos-${deploymentTarget}";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p $out/bin

    cat > $out/bin/cc <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang ${commonCflags} ${commonLdflags} "\$@"
    EOF

    cat > $out/bin/c++ <<EOF
    #!${bash}/bin/bash
    exec ${clang}/bin/clang++ ${commonCflags} ${commonLdflags} "\$@"
    EOF

    chmod +x $out/bin/cc $out/bin/c++

    # llvm tooling. install_name_tool and codesign live in /usr/bin on
    # macOS — we don't ship them, the build/finalize scripts call them
    # by absolute path.
    for t in ar nm strip objdump ranlib objcopy; do
      ln -s ${llvmTools}/bin/llvm-$t $out/bin/$t
    done

    # cctools' lipo: meson's library-resolution path calls bare `lipo`
    # via Popen (darwin_get_object_archs); not in PATH from llvm-tools
    # alone. cctools' `ar`/`nm`/`strip` would shadow the llvm-* entries
    # above, so we only symlink lipo specifically.
    ln -s ${cctools}/bin/lipo $out/bin/lipo

    runHook postBuild
  '';

  dontInstall = true;
  dontFixup = true;

  passthru = {
    inherit deploymentTarget clang llvmTools;
  };
}
