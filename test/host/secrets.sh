#!/usr/bin/env bash
# Host-only check of secrets (#8) against the real Sandbox machine. Needs
# the Sandbox machine running, the images built ('p4a image build') and the
# Agent token stored ('p4a secret set agent-token'). Takes a few minutes.
#
#   test/host/secrets.sh
#
# It creates two throwaway projects from public repositories (hello-world
# and spoon-knife), each with a made-up Repo token, and hello-world with a
# made-up Project secret, and removes them again at the end. It stops first
# if either project or one of those secrets exists.
#
# 1. Each Sandbox sees its own Repo token, and nothing in it holds the
#    other project's.
# 2. `podman inspect` of each Sandbox holds no token or Project secret value.
# 3. A Project secret (#77) stored before p4a new is found by its label
#    filter, appears in its own project's Sandbox at /run/secrets/<name>,
#    owned by agent with mode 0400, and nowhere in the other project's.
# 4. A replaced Repo token reaches a Sandbox at its next start (which
#    recreates it, keeping its source), and so does a removed one: a
#    project with no Repo token can't push, and says how to set one.
#
# Signing in on real tokens (Claude answering, cloning and pushing a private
# repository) is checked by test/host/sign-in.sh instead.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
p4a() { "$repo/bin/p4a" "$@"; }

projects=(hello-world spoon-knife)
repos=(octocat/Hello-World octocat/Spoon-Knife)
config="$(bash -c "source '$repo/lib/common.sh'; source '$repo/lib/podman.sh'; source '$repo/lib/project.sh'; p4a_config_dir")"

for project in "${projects[@]}"; do
  if [[ -e $config/projects/$project.conf ]] || p4a podman secret exists "podman4ai.$project.repo-token" \
    || p4a podman secret exists "podman4ai-$project-repo-token" \
    || p4a podman secret exists "podman4ai.$project.p4a-test-key"; then
    echo "The project $project or one of its test secrets already exists; this check would replace it. Stopping." >&2
    exit 2
  fi
done
p4a podman secret exists podman4ai-agent-token \
  || { echo "Store the Agent token first: p4a secret set agent-token" >&2; exit 2; }

cleanup() {
  local project
  for project in "${projects[@]}"; do
    p4a podman rm -f "podman4ai-$project" "podman4ai-$project-proxy" >/dev/null 2>&1 || true
    p4a podman network rm -f "podman4ai-$project" >/dev/null 2>&1 || true
    p4a podman volume rm -f "podman4ai-$project-source" "podman4ai-$project-claude" >/dev/null 2>&1 || true
    p4a podman secret rm "podman4ai.$project.repo-token" "podman4ai.$project.p4a-test-key" >/dev/null 2>&1 || true
    rm -f "$config/projects/$project.conf" "$config/projects/$project.allowlist"
  done
}
trap cleanup EXIT

# Made-up Repo tokens, different every run.
declare -A token
for project in "${projects[@]}"; do
  token[$project]="github_pat_p4atest_${project//-/}_$RANDOM$RANDOM"
done
p4a secret set repo-token hello-world <<< "${token[hello-world]}" >/dev/null
p4a secret set repo-token spoon-knife <<< "${token[spoon-knife]}" >/dev/null
# A Project secret for hello-world only, stored before p4a new.
key="p4atest_key_$RANDOM$RANDOM"
p4a secret set p4a-test-key hello-world <<< "$key" >/dev/null
for i in 0 1; do
  p4a new "${repos[$i]}" >/dev/null
done

echo "--- 1. Each Sandbox sees only its own Repo token"
for i in 0 1; do
  self="${projects[$i]}" other="${projects[$(( 1 - i ))]}"
  if [[ "$(p4a shell "$self" -- cat /run/secrets/repo-token)" == "${token[$self]}" ]]; then
    pass "$self's Sandbox has its own Repo token"
  else
    fail "$self's Sandbox doesn't have its own Repo token"
  fi
  # Search everywhere a secret or a copy of one could be.
  # shellcheck disable=SC2016 # $1 is expanded by sh in the Sandbox
  if p4a shell "$self" -- sh -c 'grep -rlsF -- "$1" /run /etc /home /workspace /tmp /var' _ "${token[$other]}" | grep -q .; then
    fail "$self's Sandbox can read $other's Repo token"
  else
    pass "$self's Sandbox can't see $other's Repo token"
  fi
done

echo "--- 2. podman inspect holds no token or Project secret value"
agent_token="$(p4a podman secret inspect --showsecret --format '{{.SecretData}}' podman4ai-agent-token)"
for project in "${projects[@]}"; do
  inspect="$(p4a podman inspect "podman4ai-$project" "podman4ai-$project-proxy")"
  leaked=()
  for value in "$agent_token" "${token[@]}" "$key"; do
    [[ $inspect != *"$value"* ]] || leaked+=("a secret")
  done
  if (( ${#leaked[@]} )); then
    fail "podman inspect of $project shows ${#leaked[@]} secret value(s)"
  else
    pass "podman inspect of $project shows no token or secret value"
  fi
done
unset agent_token

echo "--- 3. A Project secret reaches only its own project's Sandbox"
# p4a finds a project's secrets by their labels. (Podman has no label
# filter for secrets: through the remote connection one finds nothing.)
labels="$(p4a podman secret inspect \
  --format '{{.Spec.Name}} {{index .Spec.Labels "podman4ai.project"}} {{index .Spec.Labels "podman4ai.secret-name"}}' \
  podman4ai.hello-world.p4a-test-key podman4ai.hello-world.repo-token podman4ai.spoon-knife.repo-token)"
if [[ $labels == "podman4ai.hello-world.p4a-test-key hello-world p4a-test-key
podman4ai.hello-world.repo-token hello-world repo-token
podman4ai.spoon-knife.repo-token spoon-knife repo-token" ]]; then
  pass "each Project secret is labelled with its own project and name"
else
  fail "the Project secrets' labels aren't their projects and names: $labels"
fi
if [[ "$(p4a shell hello-world -- cat /run/secrets/p4a-test-key)" == "$key" ]]; then
  pass "hello-world's Sandbox has its Project secret at /run/secrets/p4a-test-key"
else
  fail "hello-world's Sandbox doesn't have its Project secret at /run/secrets/p4a-test-key"
fi
if [[ "$(p4a shell hello-world -- stat -L -c '%U:%G %a' /run/secrets/p4a-test-key)" == "agent:agent 400" ]]; then
  pass "the Project secret's file is owned by agent with mode 0400"
else
  fail "the Project secret's file isn't owned by agent with mode 0400"
fi
# shellcheck disable=SC2016 # $1 is expanded by sh in the Sandbox
if p4a shell spoon-knife -- test -e /run/secrets/p4a-test-key \
  || p4a shell spoon-knife -- sh -c 'grep -rlsF -- "$1" /run /etc /home /workspace /tmp /var' _ "$key" | grep -q .; then
  fail "spoon-knife's Sandbox can see hello-world's Project secret"
else
  pass "spoon-knife's Sandbox can't see hello-world's Project secret"
fi

echo "--- 4. A changed or removed Repo token reaches the Sandbox at its next start"
# Replace hello-world's Repo token, then restart: p4a start recreates the
# Sandbox, keeping its source.
replaced="github_pat_p4atest_replaced_$RANDOM$RANDOM"
p4a secret set repo-token hello-world <<< "$replaced" >/dev/null
p4a stop hello-world >/dev/null
p4a start hello-world >/dev/null
if [[ "$(p4a shell hello-world -- cat /run/secrets/repo-token)" == "$replaced" ]]; then
  pass "a replaced Repo token reaches the Sandbox after a restart"
else
  fail "the Sandbox doesn't have the replaced Repo token after a restart"
fi
if p4a shell hello-world -- test -d /workspace/Hello-World/.git; then
  pass "recreating the Sandbox kept its source"
else
  fail "recreating the Sandbox lost its source"
fi

# Remove the Repo token: the Sandbox no longer gets one, and can't push.
p4a podman secret rm podman4ai.hello-world.repo-token >/dev/null
p4a stop hello-world >/dev/null
p4a start hello-world >/dev/null
if p4a shell hello-world -- test -e /run/secrets/repo-token; then
  fail "the Sandbox still has a Repo token after it was removed"
else
  pass "a removed Repo token is gone from the Sandbox after a restart"
fi
if out="$(p4a shell hello-world -- sh -c 'git push --dry-run origin HEAD:refs/heads/p4a-test 2>&1')"; then
  fail "the push succeeded"
elif [[ $out == *"p4a secret set repo-token hello-world"* ]]; then
  pass "the push failed, saying how to set a Repo token"
else
  fail "the push failed without saying how to set a Repo token: $out"
fi

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
