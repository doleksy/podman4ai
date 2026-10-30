#!/usr/bin/env bash
# Host-only check of the Base image's tooling (#10) in a real Sandbox.
# Needs the Sandbox machine running, the images built ('p4a image build')
# and the Agent token stored ('p4a secret set agent-token'). Takes a few
# minutes.
#
#   test/host/base-image.sh
#
# It creates a throwaway project from octocat/Hello-World and removes it
# again at the end. It stops first if that project already exists.
#
# 1. Every tool the Base image promises runs in the Sandbox, as its
#    non-root user.
# 2. npm install -g, uv tool install and pip install --user work without
#    root, and what they installed is still there after p4a stop and start.
# 3. Claude Code's self-updater, telemetry and error reporting are off.
# 4. tmux has the mouse on and shows the project's name.
# 5. The image's labels say when it was built and which Claude Code it has.
#
# test/host/image-build.sh checks that the build itself went only through
# the Egress proxy, to build-Allowlist domains.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
p4a() { "$repo/bin/p4a" "$@"; }

project=hello-world
config="$(bash -c "source '$repo/lib/common.sh'; source '$repo/lib/podman.sh'; source '$repo/lib/project.sh'; p4a_config_dir")"
if [[ -e $config/projects/$project.conf ]] || p4a podman container exists "podman4ai-$project"; then
  echo "The project $project already exists; this check would remove it. Stopping." >&2
  exit 2
fi
p4a podman secret exists podman4ai-agent-token \
  || { echo "Store the Agent token first: p4a secret set agent-token" >&2; exit 2; }

cleanup() {
  p4a podman rm -f -t 0 "podman4ai-$project" "podman4ai-$project-proxy" >/dev/null 2>&1 || true
  p4a podman network rm -f "podman4ai-$project" >/dev/null 2>&1 || true
  p4a podman volume rm -f "podman4ai-$project-source" "podman4ai-$project-claude" >/dev/null 2>&1 || true
  rm -f "$config/projects/$project.conf"
}
trap cleanup EXIT
p4a new octocat/Hello-World >/dev/null
in_sandbox() { p4a shell "$project" -- "$@" < /dev/null; }

echo "--- 1. Every tool runs, as the non-root user"
uid="$(in_sandbox id -u)"
if [[ $uid != 0 ]]; then pass "the Sandbox runs as $(in_sandbox id -un) (uid $uid)"; else fail "the Sandbox runs as root"; fi
for tool in node npm python3 pip uv uvx ruff ty bun bunx gh rg jq fzf delta less nano tmux claude; do
  flag=--version
  [[ $tool == tmux ]] && flag=-V
  if out="$(in_sandbox "$tool" "$flag" 2>&1)"; then
    pass "$tool runs ($(head -1 <<< "$out"))"
  else
    fail "$tool doesn't run: $(head -3 <<< "$out")"
  fi
done
if [[ "$(in_sandbox printenv EDITOR)" == nano ]]; then pass "EDITOR is nano"; else fail "EDITOR isn't nano"; fi

echo "--- 2. User-level installs work without root and survive a restart"
if in_sandbox npm install -g semver >/dev/null 2>&1; then pass "npm install -g works"; else fail "npm install -g failed"; fi
if in_sandbox uv tool install pycowsay >/dev/null 2>&1; then pass "uv tool install works"; else fail "uv tool install failed"; fi
if in_sandbox pip install --user --quiet six >/dev/null 2>&1; then pass "pip install --user works"; else fail "pip install --user failed"; fi
p4a stop "$project" >/dev/null
p4a start "$project" >/dev/null
if in_sandbox semver 1.2.3 >/dev/null 2>&1; then pass "the npm global package is still there after a restart"; else fail "the npm global package is gone after a restart"; fi
if in_sandbox pycowsay moo >/dev/null 2>&1; then pass "the uv tool is still there after a restart"; else fail "the uv tool is gone after a restart"; fi
if in_sandbox python3 -c 'import six' 2>/dev/null; then pass "the pip --user package is still there after a restart"; else fail "the pip --user package is gone after a restart"; fi

echo "--- 3. Claude Code's self-updater, telemetry and error reporting are off"
for var in DISABLE_AUTOUPDATER DISABLE_TELEMETRY DISABLE_ERROR_REPORTING; do
  if [[ "$(in_sandbox printenv "$var")" == 1 ]]; then pass "$var=1"; else fail "$var isn't 1 in the Sandbox"; fi
done

echo "--- 4. tmux"
status_left="$(in_sandbox sh -c 'tmux new -d -s p4a-check && tmux show -gv status-left; tmux show -gv mouse; tmux kill-server' 2>&1)"
if [[ $status_left == *"$project"* ]]; then pass "tmux's status bar shows $project"; else fail "tmux's status bar doesn't show $project: $status_left"; fi
if [[ $(tail -1 <<< "$status_left") == on ]]; then pass "tmux has the mouse on"; else fail "tmux's mouse isn't on"; fi

echo "--- 5. The image's labels"
created="$(p4a podman image inspect --format '{{index .Labels "org.opencontainers.image.created"}}' localhost/podman4ai-base)"
if [[ $created =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then pass "built at $created"; else fail "no build date label (got '$created')"; fi
labelled="$(p4a podman image inspect --format '{{index .Labels "podman4ai.claude-code-version"}}' localhost/podman4ai-base)"
installed="$(in_sandbox claude --version)"
if [[ -n $labelled && ${installed%% *} == "$labelled" ]]; then pass "labelled with Claude Code $labelled, which it has"; else fail "Claude Code label '$labelled' doesn't match '$installed'"; fi
echo "Base image size: $(p4a podman image inspect --format '{{.Size}}' localhost/podman4ai-base | awk '{ printf "%.0f MB", $1 / 1000000 }')"

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
