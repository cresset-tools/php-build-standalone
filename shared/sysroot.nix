# Old-glibc sysroot — assembled from CentOS 7 Vault RPMs.
#
# Mirrors python-build-standalone's "build inside Debian Jessie" trick: we
# don't build glibc ourselves. We fetch a known-good binary glibc (2.17,
# the manylinux2014 baseline — same one CentOS 7 / RHEL 7 ship) plus the
# devtoolset-11 libstdc++ static archive (which is GCC 11.2's libstdc++
# built *against* glibc 2.17). Both are extracted into a unified sysroot
# tree at $out, which the clang wrapper then targets via --sysroot.
#
# Why these specific RPMs:
#   - glibc                    — runtime libs (libc.so, libpthread.so, etc.)
#   - glibc-devel              — startup files (crt1.o, crti.o, crtn.o) +
#                                linker scripts in /usr/lib64/
#   - glibc-headers            — system header files in /usr/include/
#   - kernel-headers           — Linux UAPI headers in /usr/include/linux/
#   - devtoolset-11-libstdc++  — libstdc++.a (the C++ runtime as a static
#                                archive, glibc-2.17-targeting) + C++
#                                standard library headers
#
# RPMs are content-addressable on vault.centos.org. CentOS 7 is EOL but the
# vault is a long-term archive — these URLs and hashes will stay valid.
{ stdenvNoCC, fetchurl, cpio, rpm, lib }:
let
  vault = "https://vault.centos.org/7.9.2009";
  scl   = "https://vault.centos.org/centos/7/sclo/x86_64/rh/Packages/d";

  rpms = [
    {
      name = "glibc-2.17-326.el7_9.3.x86_64.rpm";
      url  = "${vault}/updates/x86_64/Packages/glibc-2.17-326.el7_9.3.x86_64.rpm";
      sha256 = "d2c498e78241cc2d36124d37d4771f877da25de95d6a31c1ad42e1287fdda746";
    }
    {
      name = "glibc-devel-2.17-326.el7_9.3.x86_64.rpm";
      url  = "${vault}/updates/x86_64/Packages/glibc-devel-2.17-326.el7_9.3.x86_64.rpm";
      sha256 = "9c54883a611d1da210a5b0909cd7fd415b6c99473614fab81bae9df9cf8c6be2";
    }
    {
      name = "glibc-headers-2.17-326.el7_9.3.x86_64.rpm";
      url  = "${vault}/updates/x86_64/Packages/glibc-headers-2.17-326.el7_9.3.x86_64.rpm";
      sha256 = "91de6d1a2c900bf6a030d637e635ba8bed416176970159ef63c61ba70f93a275";
    }
    {
      name = "kernel-headers-3.10.0-1160.99.1.el7.x86_64.rpm";
      url  = "${vault}/updates/x86_64/Packages/kernel-headers-3.10.0-1160.99.1.el7.x86_64.rpm";
      sha256 = "47a1d5d0a1ad064ec478ea6d44b259972b9111eefcf4ada7bbacbbe6aaf5a0be";
    }
    {
      name = "devtoolset-11-libstdc++-devel-11.2.1-9.1.el7.x86_64.rpm";
      url  = "${scl}/devtoolset-11-libstdc++-devel-11.2.1-9.1.el7.x86_64.rpm";
      sha256 = "b42d3c7ff9f4da0f7fedd354051b002fe68dbb56dc59c713c61bdf92773b3d9c";
    }
    {
      name = "devtoolset-11-gcc-11.2.1-9.1.el7.x86_64.rpm";
      url  = "${scl}/devtoolset-11-gcc-11.2.1-9.1.el7.x86_64.rpm";
      sha256 = "7049c0fdcee4412cf0e2570e2ed90e4879019aa58b9c7d1112e85260ead0ec30";
    }
  ];

  fetchedRpms = map (r: fetchurl {
    inherit (r) url sha256;
    name = r.name;
  }) rpms;
in
stdenvNoCC.mkDerivation {
  pname = "pbs-sysroot";
  version = "centos7-glibc-2.17";

  dontUnpack = true;

  nativeBuildInputs = [ cpio rpm ];

  buildPhase = ''
    runHook preBuild

    mkdir -p extracted
    pushd extracted
    ${lib.concatMapStringsSep "\n    " (rpm: ''
      echo "extracting ${rpm}..."
      rpm2cpio ${rpm} | cpio -idm --no-absolute-filenames
    '') fetchedRpms}
    popd
    echo "--- extracted top level ---"
    ls -la extracted

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    # CentOS layout puts everything under ./usr/, ./lib64/, ./etc/, plus
    # devtoolset under ./opt/rh/devtoolset-11/root/. Lay it out so that
    # --sysroot=$out works the way clang expects:
    #   $out/usr/include       — glibc + linux uapi headers
    #   $out/usr/include/c++/11 — libstdc++ headers
    #   $out/usr/lib64         — glibc libs + crt files + libstdc++.a
    #   $out/lib64             — alias for usr/lib64 (some search paths look here)
    cp -a extracted/usr $out/usr
    if [ -d extracted/lib64 ]; then
      cp -a extracted/lib64 $out/lib64
    fi

    # devtoolset landed under /opt/rh/...; pull the bits we need into
    # the standard sysroot layout. devtoolset-11 = GCC 11.2 with all its
    # support files compiled against glibc 2.17, exactly the toolchain
    # PBS-style "modern compiler against old sysroot" needs.
    dts=extracted/opt/rh/devtoolset-11/root/usr/lib/gcc/x86_64-redhat-linux/11

    # libstdc++ headers (#include <vector>, <string>, etc.) — clang's
    # libstdc++ stdlib mode needs these.
    cp -a extracted/opt/rh/devtoolset-11/root/usr/include/c++ $out/usr/include/

    # Static C++ runtime archive (positional LDFLAG when we statically
    # link C++ into PHP).
    cp $dts/libstdc++.a            $out/usr/lib64/libstdc++.a
    cp $dts/libstdc++_nonshared.a  $out/usr/lib64/libstdc++_nonshared.a

    # gcc-internal startup files. clang's Linux driver hard-codes the
    # names crtbeginS.o / crtendS.o (PIC) and crtbegin.o / crtend.o
    # (non-PIC) and looks for them on its -B search path. They handle
    # __init_array and similar constructor/destructor wiring; without
    # them every link fails.
    cp $dts/crtbegin.o   $out/usr/lib64/
    cp $dts/crtbeginS.o  $out/usr/lib64/
    cp $dts/crtbeginT.o  $out/usr/lib64/
    cp $dts/crtend.o     $out/usr/lib64/
    cp $dts/crtendS.o    $out/usr/lib64/

    # libgcc archives — clang/gcc emit calls to runtime helpers
    # (__divti3, __floatundisf, __register_frame_info, ...) and the
    # implementations live in libgcc.a + libgcc_eh.a. We use them
    # instead of compiler-rt's builtins so the C++ unwinder (which
    # libstdc++ pulls in) gets a matching glibc-2.17-targeted runtime.
    cp $dts/libgcc.a      $out/usr/lib64/
    cp $dts/libgcc_eh.a   $out/usr/lib64/
    # NB: we deliberately do NOT install devtoolset's libgcc_s.so. It is
    # a linker script that GROUP-references /lib64/libgcc_s.so.1 (CentOS
    # base, gcc 4.8 era, not part of devtoolset). With -static-libgcc on
    # the clang wrapper, libgcc.a + libgcc_eh.a are used directly and
    # the .so script never gets consulted.

    # CentOS 7's libc.so / libpthread.so / libm.so are linker scripts
    # with absolute path references (/lib64/libc.so.6, /usr/lib64/libc_nonshared.a,
    # AS_NEEDED ( /lib/ld-linux-x86-64.so.2 )). When the linker runs with
    # --sysroot=$out, GNU ld auto-prepends the sysroot to absolute paths
    # *only if* the prefixed path actually exists. Where it doesn't (like
    # /lib for the 32-bit dynamic linker that we don't ship), the AS_NEEDED
    # silently no-ops, which is what we want. So we leave these scripts
    # as-is.

    # Sanity print the layout for debugging.
    echo "--- sysroot top-level ---"
    ls $out
    echo "--- lib64 sample ---"
    ls $out/usr/lib64 | head -20
    echo "--- crt files present? ---"
    ls $out/usr/lib64/crt*.o 2>/dev/null || echo "no crt files at usr/lib64"
    echo "--- libstdc++.a present ---"
    ls -la $out/usr/lib64/libstdc++.a

    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "CentOS 7 / glibc 2.17 sysroot for portable Linux builds";
    platforms = [ "x86_64-linux" ];
  };
}
