# Shared setup for the Egress proxy tests.
#
# Each test runs the real proxy program under node on the Host, next to a
# stand-in upstream web server on localhost, and talks to the proxy with
# test/proxy-client.js. Nothing leaves the Host: allowed tests reach only
# localhost, and other names are either refused or under .invalid, which
# never resolves.

P4A_REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PROXY_LOG="$BATS_TEST_TMPDIR/proxy.log"

setup() {
  _start_upstream
}

teardown() {
  local pid
  for pid in ${PROXY_PID:-} ${UPSTREAM_PID:-}; do
    kill "$pid" 2>/dev/null || true
  done
}

# A path in the form node (a Windows program under Git Bash) understands.
_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Wait until FILE has a line matching REGEX and print its last field.
_wait_for_port() {
  local file=$1 regex=$2 line i
  for (( i = 0; i < 100; i++ )); do
    line="$(grep -E "$regex" "$file" 2>/dev/null | head -1 || true)"
    if [[ -n $line ]]; then
      echo "${line##* }"
      return 0
    fi
    sleep 0.1
  done
  echo "timed out waiting for '$regex' in $file:" >&2
  cat "$file" >&2
  return 1
}

_start_upstream() {
  node "$(_native_path "$P4A_REPO/test/fake/upstream.js")" > "$BATS_TEST_TMPDIR/upstream.out" 2>&1 &
  UPSTREAM_PID=$!
  UPSTREAM_PORT="$(_wait_for_port "$BATS_TEST_TMPDIR/upstream.out" '^listening on port ')"
}

# start_proxy ALLOWLIST [ALLOWED_PORTS]
# Start the Egress proxy with this Allowlist (entries separated by spaces or
# newlines). It may reach only ALLOWED_PORTS (space separated; "" for the
# proxy's own default), by default the stand-in upstream's port.
start_proxy() {
  P4A_ALLOWLIST="$1" P4A_PROXY_LISTEN_PORT=0 P4A_PROXY_ALLOWED_PORTS="${2-$UPSTREAM_PORT}" \
    node "$(_native_path "$P4A_REPO/images/proxy/egress-proxy.js")" > "$PROXY_LOG" 2>&1 &
  PROXY_PID=$!
  PROXY_PORT="$(_wait_for_port "$PROXY_LOG" 'listening on port ')"
}

# through_proxy connect HOST:PORT | get URL
# Make one request through the proxy and print what came back: the status
# line, then (if any) the body.
through_proxy() {
  node "$(_native_path "$P4A_REPO/test/proxy-client.js")" "$PROXY_PORT" "$@"
}

# The proxy's log lines after start-up, without their timestamps.
proxy_log() {
  grep -v 'listening on port' "$PROXY_LOG" | cut -d' ' -f2- || true
}
