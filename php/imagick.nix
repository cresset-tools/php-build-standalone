# imagick — PECL extension binding ImageMagick's MagickWand C API to PHP.
# Built via the just-installed bin/phpize, mirroring xdebug.nix.
#
# Depends on `php` (for phpize/php-config/build files) and `imagemagick`
# (for libMagickWand + headers under include/ImageMagick-7/). PHP's
# transitive deps are reported by phpize+php-config so we don't list
# them again here.
#
# `imagickSpec` is from sources.imagickVersions.<series> — parallel to
# xdebugSpec / phpSpec. Kept as a separate arg so flake.nix can pair
# different imagick releases with different PHP variants in the future.
{ mkDep, pkgs, php, imagemagick, imagickSpec }:
mkDep {
  name = "imagick";
  buildScript = ./build-imagick.sh;
  version = imagickSpec.version;
  src = pkgs.fetchurl { inherit (imagickSpec) url sha256; };
  deps = [ php imagemagick ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
