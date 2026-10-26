#!/usr/bin/env bash
# Host-only check of `p4a image build` against the real Sandbox machine
# (#5). Needs the Sandbox machine running. Takes several minutes.
#
#   test/host/image-build.sh
#
# 1. A test build with a deliberately bad step (fetching a domain that
#    isn't on the build Allowlist) fails, and the proxy refused that domain.
#    It runs a copy of p4a whose Base image Containerfile has the extra
#    step, so nothing in this checkout changes.
# 2. The real build succeeds, and its proxy allowed only build-Allowlist
#    domains and refused none.
# 3. The Base image has no sudo and runs as a non-root user by default.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

# The build Allowlist, one domain per line, sorted.
build_allowlist="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$repo/share/build-allowlist" | grep -v '^$' | sort)"

# Print the domains on the "NAME: domain domain..." line of p4a's report.
reported() {
  sed -n "s/^  $1: //p" <<< "$2" | tr ' ' '\n' | grep -v '^(none)$' | grep -v '^$' || true
}

echo "--- 1. A build step that reaches a non-allowlisted domain"
bad="$(mktemp -d)"
trap 'rm -rf "$bad"' EXIT
cp -r "$repo/bin" "$repo/lib" "$repo/share" "$repo/images" "$bad/"
echo 'RUN curl -fsS -o /dev/null https://example.com' >> "$bad/images/base/Containerfile"
if out="$("$bad/bin/p4a" image build 2>&1)"; then
  fail "the bad build succeeded"
else
  pass "the bad build failed"
fi
grep -A3 '^Egress proxy' <<< "$out" || true
if reported refused "$out" | grep -qx example.com; then
  pass "the proxy refused example.com"
else
  fail "the proxy didn't refuse example.com"
fi

echo "--- 2. The real build"
if out="$("$repo/bin/p4a" image build 2>&1)"; then
  pass "the build succeeded"
else
  fail "the build failed:"
  tail -20 <<< "$out"
fi
grep -A3 '^Egress proxy' <<< "$out" || true
extra="$(comm -23 <(reported allowed "$out" | sort) <(echo "$build_allowlist"))"
if [[ -z $extra ]]; then
  pass "the proxy allowed only build-Allowlist domains"
else
  fail "the proxy allowed domains not on the build Allowlist: $extra"
fi
refused="$(reported refused "$out")"
if [[ -z $refused ]]; then
  pass "the proxy refused nothing"
else
  fail "the build tried to reach: $refused"
fi

echo "--- 3. The Base image"
p4a() { "$repo/bin/p4a" "$@"; }
if [[ "$(p4a podman run --rm localhost/podman4ai-base id -u)" != 0 ]]; then
  pass "runs as a non-root user by default ($(p4a podman run --rm localhost/podman4ai-base id -un))"
else
  fail "runs as root by default"
fi
if p4a podman run --rm --user root localhost/podman4ai-base \
    sh -c 'command -v sudo || find / -xdev -name sudo -type f | grep -q .' >/dev/null 2>&1; then
  fail "a sudo binary exists"
else
  pass "no sudo binary"
fi
if p4a podman run --rm localhost/podman4ai-base claude --version >/dev/null 2>&1; then
  pass "Claude Code is installed ($(p4a podman run --rm localhost/podman4ai-base claude --version))"
else
  fail "claude --version failed"
fi

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
