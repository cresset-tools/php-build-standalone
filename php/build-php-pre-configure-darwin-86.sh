# Darwin pre-configure setup for PHP 8.6+ ZTS. Sourced by build-php.sh in
# place of build-php-pre-configure-darwin.sh, which it runs first.
#
# This is a separate snippet rather than a file in patches/ because
# patches/ is an input to every PHP derivation: adding a file there
# changes the hash of every minor on every platform. Selecting this
# snippet in php.nix touches only the Darwin 8.6+ ZTS builds.

: "${PBS_PHP_PRE_CONFIGURE_DARWIN_BASE:?set by php.nix}"
: "${PBS_PHP_DARWIN_SCNG_PATCH:?set by php.nix}"

source "$PBS_PHP_PRE_CONFIGURE_DARWIN_BASE"

# See the patch header. No fuzz: if the anchor moves, fail here.
patch --fuzz=0 -p1 < "$PBS_PHP_DARWIN_SCNG_PATCH"
