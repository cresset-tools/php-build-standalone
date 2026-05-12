#!/usr/bin/env python3
# Per-package update orchestrator. Walks shared/update/ for *.sh
# scripts, runs them with the current (version, url, sha256) in env,
# parses their JSON output, and rewrites shared/sources.nix.
#
# Per-script discovery: filename is the attr path. Top-level scripts
# (shared/update/zlib.sh) update sources.<name>; nested directories
# (shared/update/phpVersions/8.5.sh) update sources.<dir>."<key>".
#
# Per-script contract:
#   env IN:  PBS_PNAME           — leaf name (e.g. "zlib", "8.5")
#            PBS_ATTR_PATH       — dotted path ("zlib", "phpVersions.8.5")
#            PBS_OLD_VERSION     — current version
#            PBS_OLD_URL         — current url
#            PBS_OLD_SHA256      — current sha256
#   stdout:  single-line JSON {"version", "url", "sha256"} on success
#            or {} for "no update available" / no-op
#   exit:    0 on success (including no-op); non-zero is a hard failure
#
# Rewriting: the orchestrator is the SOLE writer of sources.nix. Scripts
# only emit data. This keeps the file format under one set of rules and
# means scripts don't need to know anything about Nix syntax. Worker
# scripts run in parallel; sources.nix mutation is single-threaded.
#
# Usage:
#   scripts/update.py                       # all packages
#   scripts/update.py --package zlib        # one package, by leaf name
#   scripts/update.py --package phpVersions.8.5
#   scripts/update.py --commit              # one git commit per package
#   scripts/update.py --dry-run             # show what would change

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCES_NIX = REPO / "shared" / "sources.nix"
UPDATE_DIR = REPO / "shared" / "update"


@dataclass
class UpdateTarget:
    script: Path           # absolute path to update.sh
    attr_path: list[str]   # e.g. ["zlib"] or ["phpVersions", "8.5"]
    pname: str             # leaf attr name

    @property
    def dotted(self) -> str:
        return ".".join(self.attr_path)


def discover_targets() -> list[UpdateTarget]:
    targets: list[UpdateTarget] = []
    for script in sorted(UPDATE_DIR.rglob("*.sh")):
        rel = script.relative_to(UPDATE_DIR)
        parts = list(rel.parts)
        parts[-1] = parts[-1].removesuffix(".sh")
        targets.append(UpdateTarget(
            script=script,
            attr_path=parts,
            pname=parts[-1],
        ))
    return targets


def read_sources() -> dict:
    out = subprocess.run(
        ["nix", "eval", "--json", "--file", str(SOURCES_NIX)],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def lookup(data: dict, attr_path: list[str]) -> dict:
    cur = data
    for k in attr_path:
        cur = cur[k]
    return cur


def run_script(t: UpdateTarget, current: dict) -> dict | None:
    """Run one update script. Returns parsed JSON dict, or None if noop."""
    env = os.environ.copy()
    env["PBS_PNAME"] = t.pname
    env["PBS_ATTR_PATH"] = t.dotted
    env["PBS_OLD_VERSION"] = current.get("version", "")
    env["PBS_OLD_URL"] = current.get("url", "")
    env["PBS_OLD_SHA256"] = current.get("sha256", "")

    proc = subprocess.run(
        ["bash", str(t.script)],
        env=env, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"{t.dotted}: script failed (exit {proc.returncode})\n"
            f"--- stderr ---\n{proc.stderr}\n--- stdout ---\n{proc.stdout}"
        )

    out = proc.stdout.strip()
    if not out:
        return None
    try:
        result = json.loads(out)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"{t.dotted}: script output is not valid JSON: {e}\n"
            f"stdout: {out!r}"
        )
    if not result:
        return None  # explicit {} = no-op
    for k in ("version", "url", "sha256"):
        if k not in result:
            raise RuntimeError(f"{t.dotted}: script output missing key '{k}': {result}")
    return result


# ----- sources.nix rewriting -----------------------------------------------

def find_block(text: str, attr_path: list[str]) -> tuple[int, int]:
    r"""Find (start, end) char indices of the inner body of an attrset
    block matching attr_path. The body is the text *between* the outer
    `{` and `}` (exclusive of both). Brace-counted, so nested blocks
    (e.g. phpVersions.{ "8.5" = { ... }; }) work.

    Match patterns:
      Top-level: /^  NAME = \{/ at column 0 indent 2
      Nested:    inside parent block, /^    "?KEY"? = \{/ at indent 4
    """
    if len(attr_path) == 1:
        head = re.compile(
            r'^  ' + re.escape(attr_path[0]) + r' = \{',
            re.MULTILINE,
        )
        m = head.search(text)
        if not m:
            raise KeyError(f"attr {attr_path[0]} not found in sources.nix")
        return _scan_braces(text, m.end())

    if len(attr_path) == 2:
        parent_start, parent_end = find_block(text, [attr_path[0]])
        parent = text[parent_start:parent_end]
        # Nested keys may be quoted ("8.5") or bare. Indent is 4 spaces.
        head = re.compile(
            r'^    "?' + re.escape(attr_path[1]) + r'"? = \{',
            re.MULTILINE,
        )
        m = head.search(parent)
        if not m:
            raise KeyError(f"attr {'.'.join(attr_path)} not found in sources.nix")
        body_start, body_end = _scan_braces(parent, m.end())
        return parent_start + body_start, parent_start + body_end

    raise ValueError(f"attr paths deeper than 2 not supported: {attr_path}")


def _scan_braces(text: str, after_open: int) -> tuple[int, int]:
    """Given an index just after a `{`, return (after_open, index_of_matching_close)."""
    depth = 1
    i = after_open
    while i < len(text):
        c = text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return after_open, i
        i += 1
    raise ValueError("unbalanced braces while scanning sources.nix block")


def rewrite_field(block_text: str, field: str, value: str) -> str:
    """Replace a single `  field = "...";` line within an attrset body.
    The field must already exist; we don't insert new fields."""
    pat = re.compile(
        r'(^[ \t]+' + re.escape(field) + r' = ")[^"]*(")',
        re.MULTILINE,
    )
    new, n = pat.subn(lambda m: m.group(1) + value + m.group(2), block_text, count=1)
    if n == 0:
        raise KeyError(f"field '{field}' not found in block")
    return new


def apply_update(text: str, attr_path: list[str], fields: dict) -> str:
    start, end = find_block(text, attr_path)
    body = text[start:end]
    for k, v in fields.items():
        body = rewrite_field(body, k, v)
    return text[:start] + body + text[end:]


# ----- driver --------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", "-p", action="append", default=[],
                    help="Update only this package (repeatable). Match by "
                         "leaf name (zlib) or dotted path (phpVersions.8.5).")
    ap.add_argument("--dry-run", "-n", action="store_true",
                    help="Print proposed changes; don't touch sources.nix.")
    ap.add_argument("--commit", action="store_true",
                    help="git-commit each package's bump separately.")
    ap.add_argument("--workers", "-j", type=int, default=4,
                    help="Parallel script workers (default 4).")
    args = ap.parse_args()

    targets = discover_targets()
    if args.package:
        wanted = set(args.package)
        targets = [t for t in targets if t.pname in wanted or t.dotted in wanted]
        if not targets:
            print(f"no update scripts match: {args.package}", file=sys.stderr)
            return 2

    sources = read_sources()

    # Run all scripts in parallel; collect (target, result) pairs.
    results: list[tuple[UpdateTarget, dict | None, Exception | None]] = []
    log_lock = threading.Lock()

    def worker(t: UpdateTarget):
        try:
            cur = lookup(sources, t.attr_path)
        except KeyError:
            return (t, None, RuntimeError(
                f"{t.dotted}: no entry in sources.nix; "
                f"the script exists but the attr does not"))
        with log_lock:
            print(f"  {t.dotted}: checking (current {cur.get('version','?')})", file=sys.stderr)
        try:
            return (t, run_script(t, cur), None)
        except Exception as e:
            return (t, None, e)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        for r in ex.map(worker, targets):
            results.append(r)

    # Apply rewrites sequentially. Single-writer: avoids interleaved
    # text edits stomping each other.
    text = SOURCES_NIX.read_text()
    any_changes = False
    failures = 0

    for t, new, err in results:
        if err is not None:
            print(f"FAIL {t.dotted}: {err}", file=sys.stderr)
            failures += 1
            continue
        cur = lookup(sources, t.attr_path)
        if new is None:
            print(f"  {t.dotted}: no-op")
            continue
        # Skip if nothing actually changed.
        if all(new.get(k) == cur.get(k) for k in ("version", "url", "sha256")):
            print(f"  {t.dotted}: already {new['version']}")
            continue

        old_v = cur.get("version", "?")
        new_v = new["version"]
        print(f"  {t.dotted}: {old_v} -> {new_v}")

        text = apply_update(text, t.attr_path, {
            "url": new["url"],
            "sha256": new["sha256"],
            "version": new_v,
        })
        any_changes = True

        if args.commit and not args.dry_run:
            SOURCES_NIX.write_text(text)
            subprocess.run(
                ["git", "-C", str(REPO), "add", str(SOURCES_NIX.relative_to(REPO))],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(REPO), "commit", "-m",
                 f"sources: {t.dotted} {old_v} -> {new_v}"],
                check=True,
            )

    if any_changes and not args.commit and not args.dry_run:
        SOURCES_NIX.write_text(text)
        print(f"updated {SOURCES_NIX.relative_to(REPO)}")
    elif args.dry_run and any_changes:
        print("(dry-run; no files written)")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
