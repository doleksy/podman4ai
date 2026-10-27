# shellcheck shell=bash
# p4a machine: create, start, stop and report on the Sandbox machine.

# Sandbox machine size: room for two or three busy Sandboxes, leaving
# Windows enough memory.
P4A_MACHINE_MEMORY_GB=12
P4A_MACHINE_CPUS=6
P4A_MACHINE_DISK_GB=200
P4A_MACHINE_SIZE="$P4A_MACHINE_MEMORY_GB GB memory, $P4A_MACHINE_CPUS CPUs, $P4A_MACHINE_DISK_GB GB disk"

p4a_machine() {
  local command="${1:-}"
  case $command in
    "" | -h | --help | help) p4a_machine_usage ;;
    create) p4a_machine_create ;;
    start) p4a_machine_start ;;
    stop) p4a_machine_stop ;;
    status) p4a_machine_status ;;
    *) p4a_usage_error "unknown command 'machine $command'" "p4a machine --help" ;;
  esac
}

p4a_machine_usage() {
  cat <<EOF
Usage: p4a machine <command>

Manage the Sandbox machine ($P4A_MACHINE): the Hyper-V Podman machine that
runs every Sandbox, with no access to Windows drives.

Commands:
  create   create it ($P4A_MACHINE_SIZE); doesn't start it
  start    start it; another running Podman machine must be stopped first
  stop     stop it
  status   show whether it exists and is running

Plain \`podman\` in other shells keeps using its own default machine.
EOF
}

# Fill these from `podman machine list`:
#   P4A_SANDBOX_STATE   missing, stopped or running (starting counts as running)
#   P4A_OTHERS_RUNNING  names of other machines that are running or starting
_p4a_read_machines() {
  P4A_SANDBOX_STATE=missing
  P4A_OTHERS_RUNNING=()
  local list name running starting state
  list="$(p4a_podman machine list --format '{{.Name}}|{{.VMType}}|{{.Running}}|{{.Starting}}')"
  while IFS='|' read -r name _ running starting; do
    # Podman marks the default connection's machine with "*", even here.
    name="${name%\*}"
    [[ -n $name ]] || continue
    state=stopped
    [[ $running == true || $starting == true ]] && state=running
    if [[ $name == "$P4A_MACHINE" ]]; then
      P4A_SANDBOX_STATE=$state
    elif [[ $state == running ]]; then
      P4A_OTHERS_RUNNING+=("$name")
    fi
  done <<< "$list"
}

_p4a_require_sandbox_machine() {
  [[ $P4A_SANDBOX_STATE != missing ]] \
    || p4a_die "the Sandbox machine $P4A_MACHINE doesn't exist yet" "create it with 'p4a machine create'"
}

# Exit with the fix unless the Sandbox machine exists and is running. For
# commands that work inside it.
p4a_require_running_sandbox_machine() {
  _p4a_read_machines
  _p4a_require_sandbox_machine
  [[ $P4A_SANDBOX_STATE == running ]] \
    || p4a_die "the Sandbox machine $P4A_MACHINE isn't running" "start it with 'p4a machine start'"
}

p4a_machine_create() {
  _p4a_read_machines
  [[ $P4A_SANDBOX_STATE == missing ]] \
    || p4a_die "the Sandbox machine $P4A_MACHINE already exists" \
      "check it with 'p4a machine status', or remove it with 'podman machine rm $P4A_MACHINE' to start over"

  echo "Creating the Sandbox machine $P4A_MACHINE (Hyper-V, $P4A_MACHINE_SIZE)..."
  CONTAINERS_CONF_OVERRIDE="$(p4a_native_path "$P4A_HOME/share/sandbox-machine.containers.conf")" \
    p4a_podman machine init \
      --provider "$P4A_PROVIDER" \
      --memory $(( P4A_MACHINE_MEMORY_GB * 1024 )) \
      --cpus "$P4A_MACHINE_CPUS" \
      --disk-size "$P4A_MACHINE_DISK_GB" \
      "$P4A_MACHINE"
  _p4a_check_no_drive_sharing
  echo "Created. Start it with: p4a machine start"
}

# Make sure the new machine shares no Windows drives, and remove it if not.
#
# The first time Podman creates a Hyper-V machine it adds shared registry
# entries, which needs admin rights, so from a normal shell it relaunches
# itself elevated. That copy doesn't inherit CONTAINERS_CONF_OVERRIDE and
# shares the drives anyway. Podman offers no command that shows a machine's
# mounts, so read them from the machine's own config file.
_p4a_check_no_drive_sharing() {
  local dir config compact=""
  dir="$(p4a_podman machine inspect --format '{{.ConfigDir.Path}}' "$P4A_MACHINE")"
  config="$(p4a_unix_path "$dir")/$P4A_MACHINE.json"
  [[ -r $config ]] && compact="$(tr -d ' \t\r\n' < "$config")"

  local problem fix
  if [[ $compact =~ \"Mounts\":(\[\]|null) ]]; then
    return 0
  elif [[ $compact == *'"Mounts":'* ]]; then
    problem="Podman shared Windows drives with the new Sandbox machine despite p4a's settings. This happens the first time Podman creates a Hyper-V machine from a normal shell, because it reruns itself as administrator without those settings"
    fix="run 'p4a machine create' once from Git Bash opened with 'Run as administrator'; day-to-day commands then work from a normal shell"
  else
    problem="couldn't check that the new Sandbox machine shares no Windows drives: no mount list in $config"
    fix="report this as a bug; Podman may have changed how it keeps machine settings"
  fi

  if p4a_podman machine rm -f "$P4A_MACHINE" >/dev/null; then
    p4a_die "$problem. The machine was removed." "$fix"
  fi
  p4a_die "$problem. p4a couldn't remove it, so don't use it." \
    "remove it with 'podman machine rm -f $P4A_MACHINE', then $fix"
}

p4a_machine_start() {
  _p4a_read_machines
  _p4a_require_sandbox_machine
  if [[ $P4A_SANDBOX_STATE == running ]]; then
    echo "The Sandbox machine $P4A_MACHINE is already running."
    return
  fi
  # Podman refuses to start a second machine, but its error doesn't say
  # what to do, so check first.
  if (( ${#P4A_OTHERS_RUNNING[@]} )); then
    local other=${P4A_OTHERS_RUNNING[0]}
    p4a_die "can't start the Sandbox machine: the Podman machine $other is running, and Podman runs only one machine at a time" \
      "stop it with 'podman machine stop $other', then run 'p4a machine start' again"
  fi

  _p4a_remove_stale_socket
  # --update-connection=false keeps plain `podman` in other shells on its
  # current default machine.
  p4a_podman machine start --update-connection=false "$P4A_MACHINE"
}

# A sign-out kills Podman's gvproxy helper but leaves its API socket behind,
# and the next start then fails with "machine is not listening on ssh port".
# Safe to remove while the machine is stopped.
_p4a_remove_stale_socket() {
  local sock
  sock="$(p4a_podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' "$P4A_MACHINE")"
  [[ -n $sock ]] || return 0
  sock="$(p4a_unix_path "$sock")"
  if [[ -e $sock ]]; then
    p4a_note "removing stale socket $sock"
    rm -f "$sock"
  fi
}

p4a_machine_stop() {
  _p4a_read_machines
  _p4a_require_sandbox_machine
  if [[ $P4A_SANDBOX_STATE == stopped ]]; then
    echo "The Sandbox machine $P4A_MACHINE is already stopped."
    return
  fi
  p4a_podman machine stop "$P4A_MACHINE"
}

p4a_machine_status() {
  _p4a_read_machines
  case $P4A_SANDBOX_STATE in
    missing)
      echo "Sandbox machine $P4A_MACHINE: not created"
      echo "  create it with: p4a machine create"
      ;;
    *) echo "Sandbox machine $P4A_MACHINE: $P4A_SANDBOX_STATE" ;;
  esac
  # Podman lets a WSL machine start while the Sandbox machine runs (ADR 0004).
  if [[ $P4A_SANDBOX_STATE == running ]]; then
    local other
    for other in "${P4A_OTHERS_RUNNING[@]}"; do
      echo "  warning: the Podman machine $other is also running; stop it with 'podman machine stop $other'"
    done
  fi
}
