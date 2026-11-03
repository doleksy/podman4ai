#!/usr/bin/env bats
# The port forwarder behind p4a port: passes connections from Windows
# through to one port of the Sandbox, and logs the ones it can't.

load proxy-helpers

FORWARDER_LOG="$BATS_TEST_TMPDIR/forwarder.log"

teardown() {
  local pid
  for pid in ${FORWARDER_PID:-} ${UPSTREAM_PID:-}; do
    kill "$pid" 2>/dev/null || true
  done
}

# start_forwarder TARGET_PORT
# Start the port forwarder passing connections to 127.0.0.1:TARGET_PORT.
start_forwarder() {
  P4A_FORWARD_TO="127.0.0.1:$1" P4A_FORWARD_LISTEN_PORT=0 \
    node "$(_native_path "$P4A_REPO/images/proxy/port-forward.js")" > "$FORWARDER_LOG" 2>&1 &
  FORWARDER_PID=$!
  FORWARDER_PORT="$(_wait_for_port "$FORWARDER_LOG" 'listening on port ')"
}

# GET PATH through the forwarder; print the body, or "error CODE".
get_through_forwarder() {
  node -e '
    const http = require("http");
    http.get({ host: "127.0.0.1", port: Number(process.argv[1]), path: process.argv[2] }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (d) => process.stdout.write(d));
    }).on("error", (err) => console.log("error", err.code));' "$FORWARDER_PORT" "$1"
}

@test "a connection to the forwarder reaches the Sandbox port and the reply comes back" {
  start_forwarder "$UPSTREAM_PORT"
  run get_through_forwarder /dev-server/page
  [ "$status" -eq 0 ]
  [[ "$output" == "hello from upstream: GET /dev-server/page host=127.0.0.1:$FORWARDER_PORT" ]]
}

@test "with nothing listening on the Sandbox port, the connection is closed and the log says why" {
  # A port nothing listens on: the stand-in upstream's, once it's gone.
  kill "$UPSTREAM_PID"
  wait "$UPSTREAM_PID" 2>/dev/null || true
  start_forwarder "$UPSTREAM_PORT"
  run get_through_forwarder /
  [[ "$output" == "error "* ]]
  # The log names the target and the error, and the usual cause: a dev
  # server listening only on the Sandbox's own localhost.
  grep -q "failed 127.0.0.1:$UPSTREAM_PORT ECONNREFUSED" "$FORWARDER_LOG"
  grep -q "0.0.0.0" "$FORWARDER_LOG"
}
