#!/usr/bin/env bash
# Host-only check of p4a port (#15) against the real Sandbox machine. Needs
# the Sandbox machine running, the images built ('p4a image build') and the
# Agent token stored ('p4a secret set agent-token'). Takes a few minutes.
#
#   test/host/port.sh
#
# It creates a throwaway project (spoon-knife, from octocat/Spoon-Knife),
# runs a small web server in its Sandbox on port 38917 (or
# $P4A_PORT_TEST_PORT), and removes the project again at the end. It stops
# first if the project exists or something on Windows already uses the port.
#
# 1. Before p4a port, nothing on Windows reaches the Sandbox's server.
# 2. After p4a port, Windows reaches it at localhost:PORT, and not at any
#    of the Host's other addresses (so not from another device).
# 3. The Sandbox still can't reach the internet directly.
# 4. The port comes back after p4a stop and p4a start.
# 5. After p4a unport, nothing on Windows reaches it.
#
# Not covered here (check by hand, see docs/vscode.md): reaching it from
# another device on the network, and VS Code attach.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
p4a() { "$repo/bin/p4a" "$@"; }

project=spoon-knife
port=${P4A_PORT_TEST_PORT:-38917}
config="$(bash -c "source '$repo/lib/common.sh'; source '$repo/lib/podman.sh'; source '$repo/lib/project.sh'; p4a_config_dir")"

if [[ -e $config/projects/$project.conf ]]; then
  echo "The project $project already exists; this check would remove it. Stopping." >&2
  exit 2
fi

# Print what http://HOST:PORT/ answers, or nothing if it can't be reached.
fetch() {
  curl --silent --max-time 5 --noproxy '*' "http://$1:$port/" 2>/dev/null || true
}

if [[ -n "$(fetch 127.0.0.1)" ]]; then
  echo "Something on Windows already answers on port $port; set P4A_PORT_TEST_PORT to a free one. Stopping." >&2
  exit 2
fi

cleanup() {
  p4a podman rm -f "podman4ai-$project" "podman4ai-$project-proxy" "podman4ai-$project-port-$port" >/dev/null 2>&1 || true
  p4a podman network rm -f "podman4ai-$project" >/dev/null 2>&1 || true
  p4a podman volume rm -f "podman4ai-$project-source" "podman4ai-$project-claude" >/dev/null 2>&1 || true
  rm -f "$config/projects/$project.conf" "$config/projects/$project.allowlist"
}
trap cleanup EXIT

p4a new octocat/Spoon-Knife >/dev/null

# Start a web server in the Sandbox on 0.0.0.0:PORT that answers with a
# word only it knows, and wait until it answers inside the Sandbox.
word="p4a-port-test-$RANDOM$RANDOM"
start_server() {
  # shellcheck disable=SC2016 # $1 and $2 are expanded by sh in the Sandbox
  p4a shell "$project" -- sh -c 'nohup node -e "require(\"http\").createServer((q, r) => r.end(process.argv[1])).listen(Number(process.argv[2]), \"0.0.0.0\")" "$1" "$2" > /tmp/p4a-port-test.log 2>&1 &' _ "$word" "$port"
  local i
  for (( i = 0; i < 20; i++ )); do
    p4a shell "$project" -- curl --silent --noproxy '*' "http://127.0.0.1:$port/" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "The test server didn't start in the Sandbox" >&2
  exit 1
}
start_server

echo "--- 1. Before p4a port, Windows can't reach the Sandbox's server"
if [[ -z "$(fetch 127.0.0.1)" ]]; then
  pass "localhost:$port doesn't reach the Sandbox before p4a port"
else
  fail "localhost:$port reaches the Sandbox before p4a port"
fi

echo "--- 2. After p4a port, only Windows localhost reaches it"
p4a port "$project" "$port" >/dev/null
if [[ "$(fetch 127.0.0.1)" == "$word" ]]; then
  pass "localhost:$port reaches the Sandbox's server"
else
  fail "localhost:$port doesn't reach the Sandbox's server"
fi
# Every other IPv4 address of the Host: what another device would use.
addresses="$(node -e '
  for (const list of Object.values(require("os").networkInterfaces()))
    for (const a of list) if (a.family === "IPv4" && !a.internal) console.log(a.address)')"
others=0
while read -r address; do
  [[ -n $address ]] || continue
  others=$((others + 1))
  if [[ -n "$(fetch "$address")" ]]; then
    fail "port $port answers on the Host's address $address, so other devices could reach it"
  else
    pass "port $port doesn't answer on the Host's address $address"
  fi
done <<< "$addresses"
(( others )) || echo "SKIP  the Host has no other IPv4 address to check"
# IPv4 and IPv6: only loopback (127.0.0.1 or [::1]) may listen on it.
if netstat -ano | tr -d '\r' | grep -E "LISTENING" | grep -E ":$port " \
    | grep -vqE "(127\.0\.0\.1|\[::1\]):$port "; then
  fail "something on Windows listens on port $port on an address other than loopback"
else
  pass "Windows listens on port $port only on loopback"
fi

echo "--- 3. The Sandbox still can't reach the internet directly"
if p4a shell "$project" -- curl --silent --max-time 10 --noproxy '*' --output /dev/null https://example.com; then
  fail "the Sandbox reached example.com directly after p4a port"
else
  pass "the Sandbox can't reach example.com directly after p4a port"
fi

echo "--- 4. The port comes back after a restart"
p4a stop "$project" >/dev/null
p4a start "$project" >/dev/null
start_server
if [[ "$(fetch 127.0.0.1)" == "$word" ]]; then
  pass "localhost:$port reaches the Sandbox again after p4a stop and start"
else
  fail "localhost:$port doesn't reach the Sandbox after p4a stop and start"
fi

echo "--- 5. After p4a unport, Windows can't reach it"
p4a unport "$project" "$port" >/dev/null
if [[ -z "$(fetch 127.0.0.1)" ]]; then
  pass "localhost:$port doesn't reach the Sandbox after p4a unport"
else
  fail "localhost:$port still reaches the Sandbox after p4a unport"
fi

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
