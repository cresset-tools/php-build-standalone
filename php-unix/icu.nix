# ICU bundled-dep derivation. Provides libicuuc/libicui18n/libicudata/libicuio
# for PHP's intl extension. ICU is C++, so this is the first dep that pulls
# libstdc++.so into DT_NEEDED — gcc-unwrapped's lib output ships it and
# LIBRARY_PATH already points there, so this is expected and correct.
{ mkDep }:
mkDep {
  name = "icu";
}
