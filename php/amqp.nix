# amqp — PECL extension binding librabbitmq (rabbitmq-c) to PHP: the
# AMQP 0-9-1 client RabbitMQ users (Magento's queue framework,
# php-amqplib's ext-backed transports, Symfony Messenger's amqp
# transport) expect. Built via the just-installed bin/phpize, mirroring
# uv.nix.
#
# Depends on `php` (phpize/php-config/build files) and `librabbitmq`,
# which its config.m4 locates through pkg-config — see build-amqp.sh.
#
# `amqpSpec` is the value from sources.amqpVersions.<series>.
{ mkDep, pkgs, php, librabbitmq, amqpSpec }:
mkDep {
  name = "amqp";
  buildScript = ./build-amqp.sh;
  version = amqpSpec.version;
  src = pkgs.fetchurl { inherit (amqpSpec) url sha256; };
  deps = [ php librabbitmq ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
