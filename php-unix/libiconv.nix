# Darwin-only libiconv bundled-dep derivation. Linux uses glibc's iconv
# directly; macOS's apple-sdk strips legacy libiconv headers, so we bundle
# GNU libiconv. Build commands live in build-libiconv.sh.
#
# build-libiconv.sh has no -darwin suffix because libiconv is Darwin-only;
# mkDep-darwin's pathExists fallback resolves to the unsuffixed file.
{ mkDep }:
mkDep {
  name = "libiconv";
}
