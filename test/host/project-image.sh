#!/usr/bin/env bash
# Host-only check of Project images (#14) against the real Sandbox machine.
# Needs the Sandbox machine running, both images built and the Agent token
# stored. Takes a few minutes.
#
#   test/host/project-image.sh
#
# On a throwaway project (octocat/Spoon-Knife, or P4A_PROJECT_IMAGE_REPO):
# 1. A Project image adding Go is refused while go.dev isn't on the
#    project's Allowlist: the build fails and its proxy refused go.dev.
# 2. After 'p4a allow', the same build succeeds.
# 3. 'p4a recreate' puts the Sandbox on the Project image, where go runs.
# Afterwards it removes the project, its volumes, network, settings and
# Project image, even after a failure or Ctrl-C. It refuses to start if a
# project of that name already exists.
set -uo pipefail

if [[ -e /run/.containerenv || -e /.dockerenv ]]; then
  echo "project-image.sh: this is a Host-only check and can't run inside a Sandbox or other container." >&2
  exit 2
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
p4a() { "$repo/bin/p4a" "$@"; }
REPO=${P4A_PROJECT_IMAGE_REPO:-octocat/Spoon-Knife}
P="$(basename "${REPO,,}")"
IMAGE="localhost/podman4ai-project-$P"

projects_dir() {
  if [[ -n ${P4A_CONFIG_DIR:-} ]]; then
    echo "$P4A_CONFIG_DIR/projects"
  elif [[ -n ${APPDATA:-} ]]; then
    echo "$(cygpath -u "$APPDATA")/podman4ai/projects"
  else
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/podman4ai/projects"
  fi
}
settings="$(projects_dir)"

failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

# Print the domains on the "NAME: domain domain..." line of p4a's report.
reported() {
  sed -n "s/^  $1: //p" <<< "$2" | tr ' ' '\n' | grep -v '^(none)$' | grep -v '^$' || true
}

if [[ -e $settings/$P.conf ]] || p4a podman container exists "podman4ai-$P" 2>/dev/null \
    || p4a podman volume exists "podman4ai-$P-source" 2>/dev/null; then
  echo "project-image.sh: a project named $P already exists; refusing to touch it." >&2
  echo "  fix: set P4A_PROJECT_IMAGE_REPO to another small public repo (owner/repo)." >&2
  exit 2
fi

cleanup() {
  trap - EXIT INT TERM HUP
  p4a podman rm -f -t 0 "podman4ai-$P" "podman4ai-$P-proxy" >/dev/null 2>&1
  p4a podman network rm -f "podman4ai-$P" >/dev/null 2>&1
  p4a podman volume rm -f "podman4ai-$P-source" "podman4ai-$P-claude" >/dev/null 2>&1
  p4a podman image rm -f "$IMAGE" >/dev/null 2>&1
  rm -f "$settings/$P.conf" "$settings/$P.allowlist" "$settings/$P.Containerfile"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "--- Creating the throwaway project $P"
p4a new "$REPO" < /dev/null || { fail "p4a new $REPO"; exit 1; }

cat > "$settings/$P.Containerfile" <<'EOF'
FROM localhost/podman4ai-base
USER root
RUN v="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
 && curl -fsSL "https://go.dev/dl/$v.linux-amd64.tar.gz" | tar -C /usr/local -xz \
 && ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/
USER agent
EOF

echo "--- 1. Building with go.dev not on the project's Allowlist"
if out="$(p4a image build "$P" 2>&1)"; then
  fail "the build succeeded without go.dev on the Allowlist"
else
  pass "the build failed"
fi
grep -A3 '^Egress proxy' <<< "$out" || true
if reported refused "$out" | grep -qx go.dev; then
  pass "the proxy refused go.dev"
else
  fail "the proxy didn't refuse go.dev"
fi

echo "--- 2. Building after p4a allow"
p4a allow "$P" go.dev >/dev/null
p4a allow "$P" dl.google.com >/dev/null
if out="$(p4a image build "$P" 2>&1)"; then
  pass "the build succeeded"
else
  fail "the build failed:"
  tail -20 <<< "$out"
fi
grep -A3 '^Egress proxy' <<< "$out" || true

echo "--- 3. p4a recreate puts the Sandbox on the Project image"
p4a recreate "$P" < /dev/null >/dev/null || fail "p4a recreate $P"
want="$(p4a podman image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)"
have="$(p4a podman container inspect --format '{{.Image}}' "podman4ai-$P" 2>/dev/null)"
if [[ -n $want && $want == "$have" ]]; then
  pass "the Sandbox runs the Project image"
else
  fail "the Sandbox's image is ${have:-unknown}, not $IMAGE (${want:-not built})"
fi
if version="$(p4a shell "$P" -- go version < /dev/null 2>&1)"; then
  pass "go runs in the Sandbox ($version)"
else
  fail "go doesn't run in the Sandbox: $version"
fi
if [[ "$(p4a shell "$P" -- id -u < /dev/null)" != 0 ]]; then
  pass "the Sandbox still runs as a non-root user"
else
  fail "the Sandbox runs as root"
fi
# Captured first: with pipefail, grep -q exiting early makes p4a fail on SIGPIPE.
status_out="$(p4a status "$P")"
if grep -q "Project image" <<< "$status_out"; then
  pass "p4a status shows the Project image"
else
  fail "p4a status doesn't mention the Project image"
fi

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
