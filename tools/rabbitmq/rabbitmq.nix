# RabbitMQ server bundle.
#
# Repackages upstream's `generic-unix` RabbitMQ tarball. Erlang/OTP
# ships separately as the `erlang` tool — see UNBUNDLE_PLAN.md — and
# the client materializes install/erlang/ at install time via the
# `link_into: "erlang"` mechanism in this tarball's manifest. Same
# pattern tools/opensearch uses for tools/jdk. This derivation
# bypasses shared/tree.nix because all platform-specific bits live
# inside the externally-shipped Erlang tarball.
#
# Symmetric across linux + darwin: generic-unix is 100% platform-
# agnostic Erlang bytecode (.beam, .ez), the shell launchers under
# sbin/ are POSIX shell, and even the rabbitmqctl/rabbitmq-plugins
# escripts are ZIP archives of .beam files (564 of which are Elixir
# stdlib .beam files baked into the archive — Elixir is not a separate
# runtime dependency). The only platform-specific thing is the Erlang
# VM, which we inject. See shared/sources.nix `rabbitmq` for the audit.
#
# Plugin handling: RabbitMQ ships ~40 plugins inside the tarball under
# plugins/<name>-<v>/. Most are disabled-by-default; users opt in via
# `rabbitmq-plugins enable <name>`. We pre-enable rabbitmq_management
# (the web UI on port 15672) — overwhelmingly the most common plugin
# for dev workflows, and matches OpenSearch's "ship sensible default
# plugins" stance. Users can disable it with `rabbitmq-plugins
# disable rabbitmq_management`.
#
# Erlang home wiring: RabbitMQ's launcher scripts (sbin/rabbitmq-env)
# call `erl` and `escript` from PATH. We patch sbin/rabbitmq-env to
# prepend $RABBITMQ_HOME/erlang/bin to PATH. After the tool-closure
# split that path resolves through the client-materialized symlink at
# install/erlang/ — pointing at the separately-installed erlang tool
# tarball — so the bundled VM is always picked up, even when the user
# has a system Erlang of a different (potentially incompatible)
# version on PATH.
{ pkgs, rabbitmqSpec }:
let
  inherit (pkgs) stdenv lib;
  src = pkgs.fetchurl {
    url = rabbitmqSpec.url;
    inherit (rabbitmqSpec) sha512;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-rabbitmq";
  version = rabbitmqSpec.version;
  inherit src;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar xz coreutils findutils gnused ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a . "$out/"
    chmod -R u+w "$out"

    # Strip top-level license/install files that are interactive-install
    # surface, not relevant to a tarball-managed install.
    rm -f "$out"/LICENSE* "$out"/INSTALL

    # Erlang is NOT injected into install/erlang/ anymore. After the
    # tool-closure split (UNBUNDLE_PLAN.md), Erlang ships as its own
    # `kind=tool` tarball, and the client materializes install/erlang/
    # at install time as a symlink to $BOUGIE_HOME/store/erlang-<ver>/
    # — the `link_into: "erlang"` mechanism declared in this tarball's
    # manifest under requires_tools[]. The rabbitmq-env path patch
    # below still resolves through `$0/../erlang/bin` because it walks
    # the symlink.

    # Patch sbin/rabbitmq-env to prepend our bundled Erlang's bin dir to
    # PATH. Every other sbin/ script (rabbitmq-server, rabbitmqctl,
    # rabbitmq-plugins, rabbitmq-diagnostics, …) sources rabbitmq-env at
    # startup, so the prepend reaches all of them.
    #
    # We compute the bundled-bin dir from the script's own location using
    # the same `cd -P "$(dirname "$0")/.."` idiom rabbitmq-env already
    # uses for RABBITMQ_HOME (a few lines lower). Doing the resolution
    # ourselves up here means we don't depend on any of rabbitmq-env's
    # later state — keeps the patch independent of upstream's internal
    # variable layout.
    #
    # Inserted right after the `#!/bin/sh` shebang via `sed '1a ...'`.
    # The patch is idempotent across upstream releases as long as line 1
    # stays a shebang, which it must be for the file to remain executable.
    rabbitmq_env="$out/sbin/rabbitmq-env"
    [ -f "$rabbitmq_env" ] || { echo "FATAL: $rabbitmq_env missing" >&2; exit 1; }

    # Nix-escaping note: two-single-quote-$ renders as a literal `$` in
    # the shell script we're writing here. We're putting a whole multi-
    # line shell snippet inline; sed's `a` command takes backslash-
    # newline as a line separator.
    sed -i '1a\
# Prepend bundled Erlang/OTP (injected by tools/rabbitmq/rabbitmq.nix).\
# Resolves to the bundled erlang/bin dir relative to this script so the\
# tree stays relocatable.\
_pbs_erlang_bin="''$(unset CDPATH && cd -P "''$(dirname "''$0")/../erlang/bin" && pwd)"\
PATH="''$_pbs_erlang_bin:''$PATH"\
export PATH\
unset _pbs_erlang_bin\
' "$rabbitmq_env"

    grep -q '_pbs_erlang_bin' "$rabbitmq_env" \
      || { echo "FATAL: PATH-prepend patch did not apply to $rabbitmq_env" >&2; \
           head -10 "$rabbitmq_env" >&2; exit 1; }

    # Pre-enable rabbitmq_management. The enabled-plugins file format is
    # an Erlang term: a list of atoms terminated with a period.
    # rabbitmq-plugins reads this on startup via the `enabled_plugins_file`
    # config key, which defaults to $RABBITMQ_HOME/etc/rabbitmq/enabled_plugins
    # in the generic-unix layout.
    mkdir -p "$out/etc/rabbitmq"
    echo '[rabbitmq_management].' > "$out/etc/rabbitmq/enabled_plugins"

    # Audit: launcher present + executable. erl/escript checks move
    # to smoke-test time, after the install/erlang/ symlink is laid
    # down against an extracted erlang tool tarball.
    [ -x "$out/sbin/rabbitmq-server" ] \
      || { echo "FATAL: $out/sbin/rabbitmq-server not present/executable" >&2; exit 1; }

    # Sanity: no /nix/store leak. Upstream tarball is built outside
    # Nix; nothing this derivation does should introduce a /nix/store
    # reference. Tripwire for future packaging bugs.
    if grep -rlI '/nix/store/' "$out" 2>/dev/null | head -1 | grep -q .; then
      echo "FATAL: /nix/store reference leaked into RabbitMQ install tree" >&2
      grep -rlI '/nix/store/' "$out" 2>/dev/null | head -5 >&2
      exit 1
    fi

    runHook postInstall
  '';

  passthru = {
    rabbitmqVersion = rabbitmqSpec.version;
  };
}
