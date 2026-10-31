#!/usr/bin/env bash
# Run the p4a unit tests. Needs bash and node, never a real Podman.
#
#   test/run.sh            all unit tests
#   test/run.sh FILE...    just these .bats files (extra bats options allowed)
#
# Either way, first lints the shell code with shellcheck if it's on PATH,
# and stops if it finds anything.
# Uses bats from PATH if installed, otherwise fetches a pinned version via npx.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if command -v shellcheck >/dev/null 2>&1; then
  # Globs rather than a fixed file list, so a new library or helper is linted too.
  (cd "$here/.." && shellcheck -x bin/* lib/*.sh test/*.sh test/*.bash \
    test/host/*.sh test/fake/podman images/base/p4a-*) ||
    { echo "shellcheck found problems; not running the tests." >&2; exit 1; }
else
  echo "shellcheck not found; skipped linting." >&2
fi

(( $# )) || set -- "$here"
# Absolute paths: bats launched through npx on Windows otherwise resolves a
# relative test path to a Windows-style one, which `load` rejects.
args=()
for arg in "$@"; do
  if [[ -e $arg && $arg != /* ]]; then
    arg="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
  fi
  args+=("$arg")
done
set -- "${args[@]}"
if command -v bats >/dev/null 2>&1; then
  exec bats "$@"
fi
# npx is a native Windows program under Git Bash; keep the test paths in
# Unix form for bats. (The tests unset this again for p4a.)
MSYS_NO_PATHCONV=1 exec npx --yes bats@1.11.1 "$@"
