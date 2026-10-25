#!/usr/bin/env bats
# p4a machine create|start|stop|status: managing the Sandbox machine.

load helpers


@test "create makes a Hyper-V machine named podman4ai with 12 GB, 6 CPUs and a 200 GB disk" {
  machines "podman-machine-default wsl running"
  run p4a machine create
  [ "$status" -eq 0 ]
  local init
  init="$(podman_calls_starting "machine init")"
  [[ " $init " == *" --provider hyperv "* ]]
  [[ " $init " == *" --memory 12288 "* ]]
  [[ " $init " == *" --cpus 6 "* ]]
  [[ " $init " == *" --disk-size 200 "* ]]
  [[ "$init" == *" podman4ai" ]]
}

@test "create turns off Windows drive sharing for the new machine" {
  machines
  run p4a machine create
  [ "$status" -eq 0 ]
  local conf
  conf="$(podman_call_conf "machine init")"
  [[ "$conf" == *"[machine]"* ]]
  [[ "$conf" =~ volumes\ *=\ *\[\] ]]
}

@test "create removes the new machine and explains the fix if Podman shared Windows drives anyway" {
  # Podman relaunches itself as administrator the first time it creates a
  # Hyper-V machine, and that copy ignores CONTAINERS_CONF_OVERRIDE.
  machines
  sandbox_machine_mounts "$WINDOWS_DRIVE_MOUNTS"
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows drives"* ]]
  [[ "$output" == *"administrator"* ]]
  podman_calls | grep -qx "machine rm -f podman4ai"
}

@test "create removes the new machine if its drive sharing can't be checked" {
  machines
  rm "$SANDBOX_CONFIG_DIR/podman4ai.json"
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check"* ]]
  podman_calls | grep -qx "machine rm -f podman4ai"
}

@test "create treats a config without a Mounts entry as unchecked, not as sharing drives" {
  machines
  printf '{"Name":"podman4ai"}' > "$SANDBOX_CONFIG_DIR/podman4ai.json"
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check"* ]]
  [[ "$output" != *"shared Windows drives"* ]]
}

@test "create still explains the shared drives when removing the machine fails" {
  machines
  sandbox_machine_mounts "$WINDOWS_DRIVE_MOUNTS"
  fake_podman "machine rm" --stderr "Error: machine is busy" --exit 125
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows drives"* ]]
  [[ "$output" == *"couldn't remove it"* ]]
  [[ "$output" == *"podman machine rm -f podman4ai"* ]]
}

@test "create accepts a machine whose config lists no mounts at all" {
  machines
  sandbox_machine_mounts 'null'
  run p4a machine create
  [ "$status" -eq 0 ]
  ! podman_calls | grep -q "machine rm"
}

@test "create refuses when the Sandbox machine already exists" {
  machines "podman4ai hyperv stopped"
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  [ -z "$(podman_calls_starting "machine init")" ]
}

@test "status reports a Sandbox machine that doesn't exist yet and how to create it" {
  machines "podman-machine-default wsl running"
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai"*"not created"* ]]
  [[ "$output" == *"p4a machine create"* ]]
}

@test "status fails, rather than guessing, when Podman can't list machines" {
  fake_podman "machine list" --stderr "Error: something broke" --exit 125
  run p4a machine status
  [ "$status" -ne 0 ]
  [[ "$output" == *"something broke"* ]]
  [[ "$output" != *"not created"* ]]
}

@test "status reports a stopped Sandbox machine" {
  machines "podman-machine-default wsl stopped" "podman4ai hyperv stopped"
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai"*"stopped"* ]]
}

@test "status reports a running Sandbox machine" {
  machines "podman-machine-default wsl stopped" "podman4ai hyperv running"
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai"*"running"* ]]
}


@test "start starts the Sandbox machine without changing the default Podman connection" {
  machines "podman-machine-default wsl stopped" "podman4ai hyperv stopped"
  run p4a machine start
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting "machine start")" = "machine start --update-connection=false podman4ai" ]
}

@test "start explains which machine is blocking the Sandbox machine and how to stop it" {
  machines "podman-machine-default wsl running" "podman4ai hyperv stopped"
  run p4a machine start
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman-machine-default"*"running"* ]]
  [[ "$output" == *"podman machine stop podman-machine-default"* ]]
  [ -z "$(podman_calls_starting "machine start")" ]
}

@test "start treats a machine that is still starting up as blocking" {
  machines "other wsl starting" "podman4ai hyperv stopped"
  run p4a machine start
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman machine stop other"* ]]
  [ -z "$(podman_calls_starting "machine start")" ]
}

@test "start on a missing Sandbox machine says to create it" {
  machines "podman-machine-default wsl stopped"
  run p4a machine start
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a machine create"* ]]
  [ -z "$(podman_calls_starting "machine start")" ]
}

@test "start on a running Sandbox machine does nothing" {
  machines "podman4ai hyperv running"
  run p4a machine start
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ -z "$(podman_calls_starting "machine start")" ]
}

@test "start removes a stale API socket left behind by a sign-out" {
  machines "podman4ai hyperv stopped"
  local other
  other="$(dirname "$SANDBOX_SOCKET")/other-api.sock"
  touch "$SANDBOX_SOCKET" "$other"
  run p4a machine start
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX_SOCKET" ]
  [ -e "$other" ]
  [ -n "$(podman_calls_starting "machine start")" ]
}

@test "start leaves the API socket alone when the machine is already running" {
  machines "podman4ai hyperv running"
  touch "$SANDBOX_SOCKET"
  run p4a machine start
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX_SOCKET" ]
}


@test "stop stops a running Sandbox machine" {
  machines "podman4ai hyperv running"
  run p4a machine stop
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting "machine stop")" = "machine stop podman4ai" ]
}

@test "stop on a stopped Sandbox machine does nothing" {
  machines "podman4ai hyperv stopped"
  run p4a machine stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"already stopped"* ]]
  [ -z "$(podman_calls_starting "machine stop")" ]
}

@test "stop on a missing Sandbox machine says to create it" {
  machines
  run p4a machine stop
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a machine create"* ]]
  [ -z "$(podman_calls_starting "machine stop")" ]
}

@test "status warns when another machine runs alongside the Sandbox machine" {
  machines "podman4ai hyperv running" "podman-machine-default wsl running"
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai"*"running"* ]]
  [[ "$output" == *"podman-machine-default is also running"* ]]
}
