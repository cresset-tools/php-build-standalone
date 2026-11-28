# librabbitmq bundled-dep derivation. rabbitmq-c, the AMQP 0-9-1 client
# library; consumed by the `amqp` PECL extension (RabbitMQ — Magento's
# message-queue backend).
#
# Depends on openssl for AMQPS: rabbitmq-c's ENABLE_SSL_SUPPORT defaults
# ON, and amqp's TLS options (cacert/cert/key/verify) are only functional
# against an SSL-enabled librabbitmq.
#
# cmake rather than mkDep's autotools template: upstream ships no
# configure at all (the autotools build was dropped in 0.12).
{ mkDep, openssl }:
mkDep {
  name = "librabbitmq";
  deps = [ openssl ];
}
