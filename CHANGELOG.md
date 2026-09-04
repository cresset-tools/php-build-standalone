# Changelog

## [0.2.18](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.17...v0.2.18) (2026-09-04)


### Features

* **ext:** add the observability pair — excimer and opentelemetry ([13fe6cb](https://github.com/cresset-tools/php-build-standalone/commit/13fe6cb4f75d531b22674ddd1cda372829bdf544))


### Bug Fixes

* **ext:** unbreak the opentelemetry build on Darwin ([#113](https://github.com/cresset-tools/php-build-standalone/issues/113)) ([4a7a2a8](https://github.com/cresset-tools/php-build-standalone/commit/4a7a2a83459d948a562726565f1219a64b5789e0))

## [0.2.17](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.16...v0.2.17) (2026-08-26)


### Features

* **ext:** add the ReactPHP event-loop backends — ev, event and uv ([3ca8130](https://github.com/cresset-tools/php-build-standalone/commit/3ca81301df740503fbda40fce0c4211dcd81dea7))


### Dependencies

* bump pinned upstreams via scripts/update.py ([#107](https://github.com/cresset-tools/php-build-standalone/issues/107)) ([5acfa12](https://github.com/cresset-tools/php-build-standalone/commit/5acfa120ec908770cadec5c4a04ddf6908d952ca))

## [0.2.16](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.15...v0.2.16) (2026-08-18)


### Dependencies

* bump pinned upstreams (automated weekly) ([#104](https://github.com/cresset-tools/php-build-standalone/issues/104)) ([5745d66](https://github.com/cresset-tools/php-build-standalone/commit/5745d66ad745c9f36aac7bb3a4fcb65a300f368d))

## [0.2.15](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.14...v0.2.15) (2026-08-08)


### Features

* **sync:** phase 10 — run against the canonical store, one copy per host ([31e9995](https://github.com/cresset-tools/php-build-standalone/commit/31e99955d38a23b902fd1c0de1044338bf83b500))


### Dependencies

* bump pinned upstreams via scripts/update.py ([#102](https://github.com/cresset-tools/php-build-standalone/issues/102)) ([e9a2218](https://github.com/cresset-tools/php-build-standalone/commit/e9a2218c95b843767414c8cf938ba05f4c2b867d))
* bump pinned upstreams via scripts/update.py ([#99](https://github.com/cresset-tools/php-build-standalone/issues/99)) ([5f6fbd7](https://github.com/cresset-tools/php-build-standalone/commit/5f6fbd7647261110447c5873d8f7a5b96460e068))

## [0.2.14](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.13...v0.2.14) (2026-07-08)


### Features

* **tools:** add MySQL 8.0 and 8.4 server bundles ([#96](https://github.com/cresset-tools/php-build-standalone/issues/96)) ([2c78d99](https://github.com/cresset-tools/php-build-standalone/commit/2c78d99250690d7a8ccc671949e5ecf05dfe0a45))


### Dependencies

* bump pinned upstreams (automated weekly) ([#95](https://github.com/cresset-tools/php-build-standalone/issues/95)) ([ffde799](https://github.com/cresset-tools/php-build-standalone/commit/ffde7990cc72f4e54d5e19cb01c3f2c6d4c6019c))


### CI

* allow failing the darwin matrix over to GitHub-hosted macOS via a repo variable ([#93](https://github.com/cresset-tools/php-build-standalone/issues/93)) ([fa852fa](https://github.com/cresset-tools/php-build-standalone/commit/fa852fa6df18e5fd02843d28354376b4311859a7))

## [0.2.13](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.12...v0.2.13) (2026-07-02)


### Features

* **ext:** ship a default spx ini enabling the web UI on 127.0.0.1 ([#91](https://github.com/cresset-tools/php-build-standalone/issues/91)) ([cf86beb](https://github.com/cresset-tools/php-build-standalone/commit/cf86beb1370aea0f0d1206ea5ac1ea1c04957265))

## [0.2.12](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.11...v0.2.12) (2026-07-01)


### Features

* **ext:** ship the spx web UI and auto-resolve it with no php.ini ([#89](https://github.com/cresset-tools/php-build-standalone/issues/89)) ([0da8861](https://github.com/cresset-tools/php-build-standalone/commit/0da88614df6fbd8b52945b6fd4f384e6812ec1c2))

## [0.2.11](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.10...v0.2.11) (2026-06-30)


### Features

* **ext:** add php-spx profiler extension ([#84](https://github.com/cresset-tools/php-build-standalone/issues/84)) ([2a15bda](https://github.com/cresset-tools/php-build-standalone/commit/2a15bda95d86e7416580041e44f8606b7daa8db1))


### Dependencies

* bump pinned upstreams via scripts/update.py ([#83](https://github.com/cresset-tools/php-build-standalone/issues/83)) ([db55389](https://github.com/cresset-tools/php-build-standalone/commit/db553895e026476c0f70f6e292f9835a13cdec8d))

## [0.2.10](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.9...v0.2.10) (2026-06-21)


### Features

* **tools:** add mailpit SMTP test server bundle ([#80](https://github.com/cresset-tools/php-build-standalone/issues/80)) ([a78eed4](https://github.com/cresset-tools/php-build-standalone/commit/a78eed42124c4aad1268b668bc29e8840b2e695b))

## [0.2.9](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.8...v0.2.9) (2026-06-18)


### Dependencies

* bump pinned upstreams via scripts/update.py ([#78](https://github.com/cresset-tools/php-build-standalone/issues/78)) ([e1f190f](https://github.com/cresset-tools/php-build-standalone/commit/e1f190fe79eb5aebbfe282a258f8c31db6128807))

## [0.2.8](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.7...v0.2.8) (2026-06-12)


### Features

* **ext:** ship protobuf 5.35.1, freeze 4.33.6 (release 2) ([#76](https://github.com/cresset-tools/php-build-standalone/issues/76)) ([1841592](https://github.com/cresset-tools/php-build-standalone/commit/184159287f24c483ed2fe050264ec3fb32fcc5ef))

## [0.2.7](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.6...v0.2.7) (2026-06-12)


### Features

* **ext:** add protobuf native PECL extension ([#75](https://github.com/cresset-tools/php-build-standalone/issues/75)) ([e0ea871](https://github.com/cresset-tools/php-build-standalone/commit/e0ea8713520e26e2dd107ebbe0fb868f341f76a6))


### Bug Fixes

* **freeze:** hash served manifest bytes byte-exactly ([#71](https://github.com/cresset-tools/php-build-standalone/issues/71)) ([f24ef66](https://github.com/cresset-tools/php-build-standalone/commit/f24ef667ef6433d148dee223fed3e97859da400c))


### Dependencies

* bump pinned upstreams (automated weekly) ([#73](https://github.com/cresset-tools/php-build-standalone/issues/73)) ([0320420](https://github.com/cresset-tools/php-build-standalone/commit/03204208bef3dbec9e000902d9f2bf4b49a0dac8))

## [0.2.6](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.5...v0.2.6) (2026-06-04)


### Bug Fixes

* **build:** capture php -m before grep in load-audit (pipefail SIGPIPE race) ([#69](https://github.com/cresset-tools/php-build-standalone/issues/69)) ([7a3487d](https://github.com/cresset-tools/php-build-standalone/commit/7a3487d606671062e443522056b35d9b1664fa2b))
* **musl:** enable gettext (musl implements it in libc) ([#67](https://github.com/cresset-tools/php-build-standalone/issues/67)) ([79bb380](https://github.com/cresset-tools/php-build-standalone/commit/79bb3805f59f72506a7816b2c54a8076788625f0))

## [0.2.5](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.4...v0.2.5) (2026-06-03)


### Features

* add x86_64-unknown-linux-musl target (PHP + extensions) ([#64](https://github.com/cresset-tools/php-build-standalone/issues/64)) ([4cedd45](https://github.com/cresset-tools/php-build-standalone/commit/4cedd45bec29b3c1cc6230363cde38db09b1bf7e))

## [0.2.4](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.3...v0.2.4) (2026-06-03)


### Bug Fixes

* **jdk:** emit blob.size in the tool manifest ([914026e](https://github.com/cresset-tools/php-build-standalone/commit/914026e737f5d0fdb6c0c0b47b87e4a8e2bc6997))
* **jdk:** emit blob.size in the tool manifest ([ac093cc](https://github.com/cresset-tools/php-build-standalone/commit/ac093ccbfc4871daa9ce77228c6afbe02c1d07ae))

## [0.2.3](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.2...v0.2.3) (2026-05-29)


### Bug Fixes

* **freeze:** hash served manifest bytes with trailing newline ([2a0fbc9](https://github.com/cresset-tools/php-build-standalone/commit/2a0fbc9178c86cab9b9725616ebb157bcc769979))
* **freeze:** hash served manifest bytes with trailing newline ([b34eb34](https://github.com/cresset-tools/php-build-standalone/commit/b34eb34bbb6e8974e44a4e8b84c8bd425229a9c2))
* **redis:** auto-adapt to upstream dropping -lstdc++ in 8.8.0 ([3a9fad4](https://github.com/cresset-tools/php-build-standalone/commit/3a9fad49de6efac1f1b60ac7e33c73a0bb0ea966))
* **redis:** auto-adapt to upstream dropping -lstdc++ in 8.8.0 ([36ca3f2](https://github.com/cresset-tools/php-build-standalone/commit/36ca3f2ac643769716116dc45f259e975053cce4))


### Dependencies

* bump pinned upstreams via scripts/update.py ([bc22391](https://github.com/cresset-tools/php-build-standalone/commit/bc22391000c6857a7e97515951d5488da750dfbe))


### CI

* fix FlakeHub OIDC + rename deprecated app-id input ([9c2f88c](https://github.com/cresset-tools/php-build-standalone/commit/9c2f88c690e2536ddfa259f339f6c65d136810d6))
* grant id-token write to update-sources and rename app-id input ([23f17c2](https://github.com/cresset-tools/php-build-standalone/commit/23f17c255dc502a1577ff861df42a781730d0538))

## [0.2.2](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.1...v0.2.2) (2026-05-22)


### Features

* **php:** build ZTS variant alongside NTS for every PHP minor ([b885668](https://github.com/cresset-tools/php-build-standalone/commit/b885668990e1af233cdb6c6a7916f14112689fab))
* **php:** build ZTS variant alongside NTS for every PHP minor ([d218cd9](https://github.com/cresset-tools/php-build-standalone/commit/d218cd9cc3b972aea6e761e0e14c5ca02c554a9f))


### Dependencies

* bump pinned upstreams via scripts/update.py ([c71707d](https://github.com/cresset-tools/php-build-standalone/commit/c71707d53041517c8ae8f6210a53a979013e9d00))

## [0.2.1](https://github.com/cresset-tools/php-build-standalone/compare/v0.2.0...v0.2.1) (2026-05-16)


### Features

* **php:** publish php-common+xml extensions and fix store-path RPATHs ([eb8c4a0](https://github.com/cresset-tools/php-build-standalone/commit/eb8c4a082bc6f63e51d82cf4438b74a7c785dbfb))
* **php:** publish php-common+xml extensions and fix store-path RPATHs ([0bc65ab](https://github.com/cresset-tools/php-build-standalone/commit/0bc65ab1bb739f3f195eeab6b194a1f4fca45718))

## [0.2.0](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.20...v0.2.0) (2026-05-16)


### ⚠ BREAKING CHANGES

* **tools:** tool tarball binaries now require their closure libs to be installed in a sibling store/ directory and (for opensearch/rabbitmq) their requires_tools[] entries to be resolved. Clients from before bougie grows closure-walking + requires_tools support (UNBUNDLE_PLAN.md phases 0–2) cannot install these artifacts. Old self-bundled tool tarballs from prior publishes remain reachable under their original /versions/<V>/ snapshots.
* **php:** consumers who unpacked the interpreter tarball directly and expected opcache/readline/pdo/etc. to be loaded must now fetch the matching per-ext tarballs. The bougie default-install policy (separate repo) reproduces apt install php8.2-cli on top of the bare interpreter.
* **cli:** rename `bougie services up`/`down` → top-level `bougie up`/`down`
* **server:** retire `server add/remove`; document --config-required `server run`

### Features

* **tools:** split bundled C-libs and embedded runtimes out of tool tarballs ([708a948](https://github.com/cresset-tools/php-build-standalone/commit/708a948a9eb3c87f3a536ab8b70fe71f8bb62907))


### Bug Fixes

* **php:** drop pcntl from extensions attrset (now static, no .so) ([ca9ff56](https://github.com/cresset-tools/php-build-standalone/commit/ca9ff56f841b2aa4a844c1ba64ab63de8cbaa7bb))
* **php:** re-enable --with-ffi=shared, side-step glibc 2.17 string-inline macros ([0d84f38](https://github.com/cresset-tools/php-build-standalone/commit/0d84f3822c85cb71d6e3505d8322e0c8db44010b))


### Refactoring

* **php:** ship Debian-faithful interpreter tarball (Phase A+B) ([50eadc7](https://github.com/cresset-tools/php-build-standalone/commit/50eadc7071cac1e7a42f43455c5a1d05378d7e22))


### Documentation

* **cli:** rename `bougie services up`/`down` → top-level `bougie up`/`down` ([692de47](https://github.com/cresset-tools/php-build-standalone/commit/692de47b89d17da665c4c8a67b4a0b9071c4c97b))
* **server:** retire `server add/remove`; document --config-required `server run` ([e2c07e4](https://github.com/cresset-tools/php-build-standalone/commit/e2c07e4f9a0d0c198104e75c07e5c4e85d549c30))

## [0.1.20](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.19...v0.1.20) (2026-05-15)


### Features

* **php:** add xsl extension via bundled libxslt 1.1.43 ([1622efd](https://github.com/cresset-tools/php-build-standalone/commit/1622efddb5a5a4bdb7b9a27aaf740e6963a3dd66))
* **php:** add xsl extension via bundled libxslt 1.1.43 ([2941894](https://github.com/cresset-tools/php-build-standalone/commit/29418946f982795ceac482750df59dccf8446365))

## [0.1.19](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.18...v0.1.19) (2026-05-14)


### Bug Fixes

* **validate-index:** skip per-bundle blob HEAD for frozen artifacts ([d9c17e5](https://github.com/cresset-tools/php-build-standalone/commit/d9c17e591b17b4de3c4eb23dbbe070fe8a3070e5))
* **validate-index:** skip per-bundle blob HEAD for frozen artifacts ([dc37037](https://github.com/cresset-tools/php-build-standalone/commit/dc3703790121df6ef94f87da6888d078df24fc1b))

## [0.1.18](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.17...v0.1.18) (2026-05-14)


### Bug Fixes

* **index:** emit frozen section entries only for targets the leg built ([62dc57e](https://github.com/cresset-tools/php-build-standalone/commit/62dc57e070fdbb995bd0a8535dbba51a70c7a9af))
* **index:** emit frozen section entries only for targets the leg built ([0875de8](https://github.com/cresset-tools/php-build-standalone/commit/0875de87c4daa3e5f5d69cbf6fdd15d27ab54f6e))

## [0.1.17](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.16...v0.1.17) (2026-05-14)


### Features

* add erlang and rabbitmq tool bundles ([6699681](https://github.com/cresset-tools/php-build-standalone/commit/6699681b3139add575dd98995e7606ca389074bc))
* add erlang/otp tool bundle ([7b7ccda](https://github.com/cresset-tools/php-build-standalone/commit/7b7ccda2031f3ff0b35490fce1c9d3f8de50bdd9))
* add rabbitmq tool bundle ([f5089b2](https://github.com/cresset-tools/php-build-standalone/commit/f5089b220269bc5dce8e32d0e9effcba78691477))


### CI

* add dedicated build jobs for erlang and rabbitmq ([49783e2](https://github.com/cresset-tools/php-build-standalone/commit/49783e2aa8345fb787df2a7ef451f65fd44d688f))
* drop rabbitmq build job — pure repackage, no compile ([71fbfaf](https://github.com/cresset-tools/php-build-standalone/commit/71fbfafd220786d5783668df3eb8c13af9ab3834))

## [0.1.16](https://github.com/cresset-tools/php-build-standalone/compare/v0.1.15...v0.1.16) (2026-05-14)


### Features

* add jdk and opensearch tool bundles ([62f026b](https://github.com/cresset-tools/php-build-standalone/commit/62f026b88686c407eea8560db22510a1a3e07341))
* add jdk and opensearch tool bundles ([00aad87](https://github.com/cresset-tools/php-build-standalone/commit/00aad87ccb16e07c92406c5b24cea432a680901a))


### CI

* add dependabot for github-actions ([52d13db](https://github.com/cresset-tools/php-build-standalone/commit/52d13db4fc24cd37961f2e2d7347c92ee6fec5c4))
* add dependabot for github-actions ([d35b617](https://github.com/cresset-tools/php-build-standalone/commit/d35b617eabef3884d3f7b561f7826aca9cdcb50e))
* add release-please for automated releases ([531a258](https://github.com/cresset-tools/php-build-standalone/commit/531a25818feda50d0f64273974ab10bef3d4d485))
* add release-please for automated releases ([da7761a](https://github.com/cresset-tools/php-build-standalone/commit/da7761ab8e8201482bb7795f50debbce9ba2fc00))
* authenticate bot workflows via GitHub App ([f48dc22](https://github.com/cresset-tools/php-build-standalone/commit/f48dc22b999db28b2a568fd99eff45f4470d7c53))
* authenticate bot workflows via GitHub App ([0b2b36e](https://github.com/cresset-tools/php-build-standalone/commit/0b2b36e436e1617867846f6ec78969d6e22de55f))
