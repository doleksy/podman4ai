#!/usr/bin/env bats
# p4a port and unport: publishing one Sandbox port to Windows localhost.

load project-helpers

# hello-world's Sandbox exists with the fixed address p4a gives it, and is
# running (true) or not (false). Any port forwarder started for it comes up.
hello_world_state() {
  fake_podman "--connection podman4ai container exists podman4ai-hello-world" --exit 0
  fake_podman "--connection podman4ai network exists podman4ai-hello-world" --exit 0
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout "$1"
  fake_podman "--connection podman4ai container inspect --format {{index .Config.Labels \"podman4ai.address\"}} podman4ai-hello-world" \
    --stdout 10.89.1.3
  fake_podman "--connection podman4ai logs podman4ai-hello-world-port-3000" \
    --stdout "2026-11-02T10:00:00Z forwarding to 10.89.1.3:3000 listening on port 8080"
}

# Every --publish (or -p) value in every container p4a created.
published() {
  _calls 'c.args[2] === "create" ? c.args.map((a, i) => a === "--publish" || a === "-p" ? c.args[i + 1] : a.startsWith("--publish=") ? a.slice(10) : null).filter(Boolean).join("\n") || null : null'
}

@test "a Sandbox publishes no port until p4a port, which publishes it to Windows localhost only" {
  sandbox_machine_running
  p4a new octo/hello-world
  [ -z "$(published)" ]

  hello_world_state true
  run p4a port hello-world 3000
  [ "$status" -eq 0 ]
  [ "$(published)" = "127.0.0.1:3000:8080" ]
  local forwarder
  forwarder="$(create_args podman4ai-hello-world-port-3000)"
  # It passes connections to that port of the Sandbox, at its fixed address.
  has_line "P4A_FORWARD_TO=10.89.1.3:3000" <<< "$(flag_values --env <<< "$forwarder")"
  has_line "podman4ai-hello-world:ip=10.89.1.3" <<< "$(create_args podman4ai-hello-world | flag_values --network)"
  sandbox_calls | has_line "start podman4ai-hello-world-port-3000"
  [[ "$output" == *"http://localhost:3000"* ]]
}

# hello-world has port forwarders for these ports.
hello_world_ports() {
  local port names=()
  for port in "$@"; do names+=("podman4ai-hello-world-port-$port"); done
  fake_podman "--connection podman4ai ps --all --filter label=podman4ai.port-of=hello-world --format {{.Names}}" \
    --stdout "$(printf '%s\n' "${names[@]}")"
}

@test "a port published while the project is stopped comes up when it starts, after the self-check, and stops with it" {
  hello_world_exists
  hello_world_state false
  run p4a port hello-world 3000
  [ "$status" -eq 0 ]
  [ -n "$(create_args podman4ai-hello-world-port-3000)" ]
  [ -z "$(sandbox_calls | grep '^start ')" ]
  [[ "$output" == *"when hello-world starts"* ]]

  hello_world_ports 3000 5173
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ "$(sandbox_calls | grep -E '^(start|exec podman4ai-hello-world curl)' | cut -d' ' -f1-3)" = "start podman4ai-hello-world-proxy
start podman4ai-hello-world
exec podman4ai-hello-world curl
exec podman4ai-hello-world curl
exec podman4ai-hello-world curl
start podman4ai-hello-world-port-3000 podman4ai-hello-world-port-5173" ]

  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  run p4a stop hello-world
  [ "$status" -eq 0 ]
  sandbox_calls | has_line "stop podman4ai-hello-world podman4ai-hello-world-proxy podman4ai-hello-world-port-3000 podman4ai-hello-world-port-5173"
}

@test "unport removes a port's forwarder, and port with no port lists what's published" {
  hello_world_exists
  hello_world_state true
  hello_world_ports 3000 5173
  run p4a port hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"3000 -> http://localhost:3000"* ]]
  [[ "$output" == *"5173 -> http://localhost:5173"* ]]

  run p4a unport hello-world 3000
  [ "$status" -eq 0 ]
  sandbox_calls | has_line "rm -f podman4ai-hello-world-port-3000"
  [[ "$output" == *"localhost:3000"* ]]

  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  run p4a unport hello-world 8000
  [ "$status" -eq 1 ]
  [[ "$output" == *"port 8000 of hello-world isn't published"* ]]
  [ -z "$(sandbox_calls | grep '^rm ')" ]
}

@test "with no ports published, port says so" {
  hello_world_exists
  hello_world_state true
  run p4a port hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-world publishes no ports"* ]]
}

# The calls that remove, create, start or stop containers, with create's
# arguments cut down to the container's name.
container_lifecycle_calls() {
  sandbox_calls | grep -E '^(stop|rm|create|start) ' \
    | sed -E 's/^(create --name [^ ]+) .*/\1/'
}

@test "recreate keeps a project's ports, with forwarders from the current image" {
  hello_world_exists
  hello_world_state true
  hello_world_ports 3000
  run p4a recreate hello-world
  [ "$status" -eq 0 ]
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy podman4ai-hello-world-port-3000
create --name podman4ai-hello-world-proxy
create --name podman4ai-hello-world
create --name podman4ai-hello-world-port-3000
start podman4ai-hello-world-proxy
start podman4ai-hello-world
start podman4ai-hello-world-port-3000" ]
  has_line "127.0.0.1:3000:8080" <<< "$(create_args podman4ai-hello-world-port-3000 | flag_values --publish)"
}

@test "rm removes a project's port forwarders with its Sandbox" {
  hello_world_exists
  hello_world_state true
  hello_world_ports 3000
  run p4a rm hello-world < /dev/null
  [ "$status" -eq 0 ]
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy podman4ai-hello-world-port-3000" ]
}

@test "port of a port already published changes nothing" {
  hello_world_exists
  hello_world_state true
  hello_world_ports 3000
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world-port-3000" --stdout true
  run p4a port hello-world 3000
  [ "$status" -eq 0 ]
  [[ "$output" == *"already published at http://localhost:3000"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|start|rm) ')" ]
}

@test "port refuses a Sandbox created before Sandboxes had a fixed address, saying to recreate it" {
  hello_world_exists
  hello_world_state true
  fake_podman "--connection podman4ai container inspect --format {{index .Config.Labels \"podman4ai.address\"}} podman4ai-hello-world" \
    --stdout "<no value>"
  run p4a port hello-world 3000
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a recreate hello-world"* ]]
  [ -z "$(sandbox_calls | grep '^create ')" ]
}

@test "a port that can't be published on Windows is removed again, saying why" {
  hello_world_exists
  hello_world_state true
  fake_podman "--connection podman4ai start podman4ai-hello-world-port-3000" --exit 125 \
    --stderr "Error: unable to start container: address already in use"
  run p4a port hello-world 3000
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't publish port 3000"* ]]
  [[ "$output" == *"already using"* ]]
  sandbox_calls | has_line "rm -f podman4ai-hello-world-port-3000"
}

@test "a forwarder that starts but doesn't listen (an Egress proxy image from before p4a port) is removed, saying to rebuild" {
  hello_world_exists
  hello_world_state true
  fake_podman "--connection podman4ai logs podman4ai-hello-world-port-3000" \
    --stderr "Error: Cannot find module '/opt/podman4ai/port-forward.js'"
  P4A_FORWARDER_WAIT_TRIES=2 run p4a port hello-world 3000
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot find module"* ]]
  [[ "$output" == *"p4a image build"* ]]
  sandbox_calls | has_line "rm -f podman4ai-hello-world-port-3000"
}

@test "port starts a published port's forwarder again if it couldn't start with the project" {
  hello_world_exists
  hello_world_state true
  hello_world_ports 3000
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world-port-3000" --stdout false
  run p4a port hello-world 3000
  [ "$status" -eq 0 ]
  sandbox_calls | has_line "start podman4ai-hello-world-port-3000"
  [ -z "$(sandbox_calls | grep -E '^(create|rm) ')" ]
  [[ "$output" == *"Published port 3000"* ]]
}

@test "recreate removes nothing if podman can't list a project's ports" {
  hello_world_exists
  hello_world_state true
  fake_podman "--connection podman4ai ps --all --filter label=podman4ai.port-of=hello-world" --exit 125 \
    --stderr "Error: something went wrong"
  run p4a recreate hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't list the Port forwarders of hello-world"* ]]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
}

@test "port and unport report it when podman can't list a project's ports, rather than guessing" {
  hello_world_exists
  hello_world_state true
  fake_podman "--connection podman4ai ps --all --filter label=podman4ai.port-of=hello-world" --exit 125 \
    --stderr "Error: something went wrong"
  run p4a unport hello-world 3000
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't list the Port forwarders of hello-world"* ]]
  [[ "$output" != *"isn't published"* ]]
  run p4a port hello-world 3000
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't list the Port forwarders of hello-world"* ]]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
}
