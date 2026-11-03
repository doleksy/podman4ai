# shellcheck shell=bash
# p4a port and unport: publish one Sandbox port to Windows localhost.
#
# A Sandbox publishes no ports: it's on an internal network with no route
# out. Each published port is a Port forwarder of its own (ADR 0007), a
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

  local forwarder running
  forwarder="$(_p4a_forwarder_name "$project" "$port")"
  running="$(_p4a_sandbox_running "$project")"
  if _p4a_port_published "$project" "$port"; then
    # Its Port forwarder may not have started with the project (its port
    # was taken on Windows, say): try again.
    if [[ $running == true && \
        "$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$forwarder")" != true ]]; then
      p4a_sandbox_podman start "$forwarder" >/dev/null \
        || p4a_die "couldn't publish port $port of $project on Windows (see podman's message above)" \
          "check no Windows program is already using port $port, then try again; or take it back with 'p4a unport $project $port'"
      _p4a_wait_for_forwarder "$forwarder"
      echo "Published port $port of $project's Sandbox at http://localhost:$port on Windows only."
      return 0
    fi
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

  _p4a_create_forwarder "$project" "$port" \
    || p4a_die "couldn't create the Port forwarder for port $port of $project (see podman's message above)" \
      "run 'p4a port $project $port' again"
  if [[ $running != true ]]; then
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
  p4a_die "the Port forwarder didn't start. Its log: ${log:-(empty)}" \
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
  _p4a_port_published "$project" "$port" \
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

# Succeed if PROJECT publishes PORT. Exit if podman can't say (explicitly:
# callers use this as a condition, where errexit is off).
_p4a_port_published() {
  local ports
  ports="$(_p4a_project_ports "$1")" || exit 1
  grep -qx -- "$2" <<< "$ports"
}

# Print the ports PROJECT publishes, one per line, in order. Exit if
# podman can't say, explicitly, as errexit is off inside a condition.
_p4a_project_ports() {
  local prefix list name
  prefix="$(_p4a_forwarder_name "$1" "")"
  list="$(_p4a_project_forwarders "$1")" || exit 1
  [[ -n $list ]] || return 0
  while read -r name; do
    echo "${name#"$prefix"}"
  done <<< "$list" | sort -n
}

# Print the names of PROJECT's Port forwarders, one per line. Exit if
# podman can't say, so nothing acts on a list that's wrongly empty.
_p4a_project_forwarders() {
  local names
  names="$(p4a_sandbox_podman ps --all --filter "label=$P4A_PORT_OF_LABEL=$1" --format '{{.Names}}')" \
    || p4a_die "couldn't list the Port forwarders of $1 (see podman's message above)" \
      "check the Sandbox machine with 'p4a machine status', then try again"
  grep -v '^$' <<< "$names" || true
}

# _p4a_read_forwarders PROJECT ARRAY
# Set ARRAY to the names of PROJECT's Port forwarders. If podman can't
# say, this exits, except as part of a condition (stopping a project after
# a failed self-check), which goes on with an empty list.
# shellcheck disable=SC2034 # forwarder_names is a nameref: it sets the caller's array
_p4a_read_forwarders() {
  local -n forwarder_names=$2
  local list
  list="$(_p4a_project_forwarders "$1")"
  forwarder_names=()
  [[ -z $list ]] || mapfile -t forwarder_names <<< "$list"
}

# Start PROJECT's Port forwarders, if it has any. One that can't start (its
# port taken on Windows, say) is reported, not fatal: the project runs on.
_p4a_start_forwarders() {
  local forwarders=()
  _p4a_read_forwarders "$1" forwarders
  (( ${#forwarders[@]} )) || return 0
  p4a_sandbox_podman start "${forwarders[@]}" >/dev/null \
    || p4a_note "couldn't publish every port of $1 (see podman's message above); is a Windows program already using one? Once it's free, run 'p4a port $1 <port>' to try again"
}

# Exit unless PORT is a TCP port number.
_p4a_require_port() {
  if ! [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || (( $1 > 65535 )); then
    p4a_usage_error "'$1' isn't a port number (1 to 65535)" "p4a --help"
  fi
}

# _p4a_create_forwarder PROJECT PORT
# Create the Port forwarder publishing PORT of PROJECT's Sandbox.
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
