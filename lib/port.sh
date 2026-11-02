# shellcheck shell=bash
# p4a port and unport: publish one Sandbox port to Windows localhost.
#
# A Sandbox publishes no ports: it's on an internal network with no route
# out. Each published port is a port forwarder of its own (ADR 0007), a
# small container from the Egress proxy image on Podman's default network
# and the project's, published to 127.0.0.1 on Windows only. It passes
# connections to that port of the Sandbox at its fixed address, and
# nowhere else. The forwarders are the record of a project's ports: they
# start and stop with the project, and p4a recreate keeps them.

# The port each forwarder listens on in its own container. Over 1023, so
# it needs no capability.
P4A_FORWARDER_PORT=8080
# The label marking a project's forwarders, with the project's name.
P4A_PORT_OF_LABEL=podman4ai.port-of

_p4a_forwarder_name() { echo "podman4ai-$1-port-$2"; }

# p4a port PROJECT [PORT]
# Publish PORT of PROJECT's Sandbox at localhost:PORT on Windows, or with
# no port, list the ports it publishes.
p4a_port() {
  [[ $# -eq 1 || $# -eq 2 ]] || p4a_usage_error "port needs a project name, then optionally a port" "p4a --help"
  local project=$1 port=${2:-}
  [[ -z $port ]] || _p4a_require_port "$port"
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine
  [[ -n $port ]] || { _p4a_list_ports "$project"; return; }

  if _p4a_project_ports "$project" | grep -qx -- "$port"; then
    echo "Port $port of $project is already published at http://localhost:$port."
    return 0
  fi
  local sandbox address
  sandbox="$(_p4a_sandbox_name "$project")"
  address="$(p4a_sandbox_podman container inspect \
    --format "{{index .Config.Labels \"$P4A_ADDRESS_LABEL\"}}" "$sandbox")" \
    || p4a_die "couldn't find the Sandbox $sandbox for $project" "check what exists with 'p4a podman ps -a'"
  [[ $address == "$(_p4a_sandbox_ip "$project")" ]] \
    || p4a_die "the Sandbox for $project is from an older podman4ai, with no fixed address to publish its ports from" \
      "run 'p4a recreate $project' (it keeps the source and Claude config), then try again"

  local forwarder
  forwarder="$(_p4a_forwarder_name "$project" "$port")"
  _p4a_create_forwarder "$project" "$port" \
    || p4a_die "couldn't create the forwarder for port $port of $project (see podman's message above)" \
      "run 'p4a port $project $port' again"
  if [[ "$(_p4a_sandbox_running "$project")" != true ]]; then
    echo "Port $port of $project's Sandbox will be at http://localhost:$port on Windows only, when $project starts."
    return 0
  fi
  if ! p4a_sandbox_podman start "$forwarder" >/dev/null; then
    p4a_sandbox_podman rm -f "$forwarder" >/dev/null
    p4a_die "couldn't publish port $port of $project on Windows (see podman's message above)" \
      "check no Windows program is already using port $port, or publish another port"
  fi
  _p4a_wait_for_forwarder "$forwarder"
  echo "Published port $port of $project's Sandbox at http://localhost:$port on Windows only."
  echo "A server in the Sandbox must listen on 0.0.0.0 (not just 127.0.0.1) for it to reach Windows."
}

# How many times, half a second apart, p4a port checks a new forwarder is
# listening before giving up.
P4A_FORWARDER_WAIT_TRIES=${P4A_FORWARDER_WAIT_TRIES:-20}

# Wait until FORWARDER is listening. If it isn't (an Egress proxy image
# built before p4a port has no forwarder), remove it and exit.
_p4a_wait_for_forwarder() {
  local forwarder=$1 log i
  for (( i = 0; i < P4A_FORWARDER_WAIT_TRIES; i++ )); do
    log="$(p4a_sandbox_podman logs "$forwarder" 2>&1 || true)"
    [[ $log == *"listening on port"* ]] && return 0
    sleep 0.5
  done
  p4a_sandbox_podman rm -f "$forwarder" >/dev/null
  p4a_die "the port forwarder didn't start. Its log: ${log:-(empty)}" \
    "rebuild the images with 'p4a image build', then try again"
}

# p4a unport PROJECT PORT
# Stop publishing PORT of PROJECT's Sandbox.
p4a_unport() {
  [[ $# -eq 2 ]] || p4a_usage_error "unport needs a project name and a port" "p4a --help"
  local project=$1 port=$2
  _p4a_require_port "$port"
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine
  _p4a_project_ports "$project" | grep -qx -- "$port" \
    || p4a_die "port $port of $project isn't published" "see which are with 'p4a port $project'"
  p4a_sandbox_podman rm -f "$(_p4a_forwarder_name "$project" "$port")" >/dev/null
  echo "Stopped publishing port $port of $project's Sandbox at http://localhost:$port."
}

# Print the ports PROJECT publishes, and where.
_p4a_list_ports() {
  local project=$1 ports port
  ports="$(_p4a_project_ports "$project")"
  if [[ -z $ports ]]; then
    echo "$project publishes no ports. Publish one with: p4a port $project <port>"
    return 0
  fi
  echo "$project's Sandbox ports on Windows:"
  while read -r port; do
    echo "  $port -> http://localhost:$port"
  done <<< "$ports"
}

# Print the ports PROJECT publishes, one per line, in order.
_p4a_project_ports() {
  local prefix
  prefix="$(_p4a_forwarder_name "$1" "")"
  _p4a_project_forwarders "$1" | sed "s/^$prefix//" | sort -n
}

# Print the names of PROJECT's port forwarders, one per line.
_p4a_project_forwarders() {
  p4a_sandbox_podman ps --all --filter "label=$P4A_PORT_OF_LABEL=$1" --format '{{.Names}}' | grep -v '^$' || true
}

# Start PROJECT's port forwarders, if it has any. One that can't start (its
# port taken on Windows, say) is reported, not fatal: the project runs on.
_p4a_start_forwarders() {
  local forwarders=()
  mapfile -t forwarders < <(_p4a_project_forwarders "$1")
  (( ${#forwarders[@]} )) || return 0
  p4a_sandbox_podman start "${forwarders[@]}" >/dev/null \
    || p4a_note "couldn't publish every port of $1 (see podman's message above); is a Windows program already using it? See them with 'p4a port $1'"
}

# Exit unless PORT is a TCP port number.
_p4a_require_port() {
  if ! [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || (( $1 > 65535 )); then
    p4a_usage_error "'$1' isn't a port number (1 to 65535)" "p4a --help"
  fi
}

# _p4a_create_forwarder PROJECT PORT
# Create the port forwarder publishing PORT of PROJECT's Sandbox.
_p4a_create_forwarder() {
  local project=$1 port=$2 sandbox_ip
  sandbox_ip="$(_p4a_sandbox_ip "$project")"
  p4a_sandbox_podman create --name "$(_p4a_forwarder_name "$project" "$port")" \
    --label "$P4A_PORT_OF_LABEL=$project" \
    "${P4A_CONTAINER_HARDENING[@]}" \
    --network podman --network "$(_p4a_network_name "$project")" \
    --publish "127.0.0.1:$port:$P4A_FORWARDER_PORT" \
    --env "P4A_FORWARD_TO=$sandbox_ip:$port" --env "P4A_FORWARD_LISTEN_PORT=$P4A_FORWARDER_PORT" \
    "$P4A_PROXY_IMAGE" node /opt/podman4ai/port-forward.js >/dev/null
}
