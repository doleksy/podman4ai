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

@test "create turns off Hyper-V dynamic memory for the new machine" {
  machines
  run p4a machine create
  [ "$status" -eq 0 ]
  [ "$(powershell_calls_with "Set-VMMemory" | wc -l)" -eq 1 ]
  [[ "$(powershell_calls_with "Set-VMMemory")" == *"Set-VMMemory -VMName podman4ai -DynamicMemoryEnabled \$false"* ]]
}

@test "create keeps the new machine and prints the fix if turning off dynamic memory fails" {
  machines
  fake_powershell "Set-VMMemory" --exit 1 \
    --stderr "Set-VMMemory : You do not have the required permission to complete this task."
  run p4a machine create
  [ "$status" -eq 1 ]
  [[ "$output" == *"dynamic memory"* ]]
  [[ "$output" == *"Set-VMMemory -VMName podman4ai -DynamicMemoryEnabled \$false"* ]]
  [[ "$output" != *"Created."* ]]
  ! podman_calls | grep -q "machine rm"
}

@test "create doesn't touch Hyper-V memory when the new machine is removed for sharing drives" {
  machines
  sandbox_machine_mounts "$WINDOWS_DRIVE_MOUNTS"
  run p4a machine create
  [ "$status" -eq 1 ]
  [ -z "$(powershell_calls)" ]
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

@test "the Sandbox machine is found when it is Podman's default connection" {
  # Podman marks the default machine's name with "*", even in --format output.
  machines "podman-machine-default wsl stopped" "podman4ai* hyperv running"
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sandbox machine podman4ai: running"* ]]
}

@test "a default machine marked with * still counts as another running machine" {
  machines "podman-machine-default* wsl running" "podman4ai hyperv stopped"
  run p4a machine start
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman machine stop podman-machine-default'"* ]]
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

@test "status warns, with the fix, when a running Sandbox machine has Hyper-V dynamic memory on" {
  machines "podman4ai hyperv running"
  dynamic_memory True
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai: running"* ]]
  [[ "$output" == *"warning:"*"dynamic memory is on"* ]]
  [[ "$output" == *"p4a machine stop"*"Set-VMMemory -VMName podman4ai -DynamicMemoryEnabled \$false"*"p4a machine start"* ]]
}

@test "status warns, with the fix, when a stopped Sandbox machine has Hyper-V dynamic memory on" {
  machines "podman4ai hyperv stopped"
  dynamic_memory True
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai: stopped"* ]]
  [[ "$output" == *"warning:"*"dynamic memory is on"* ]]
  [[ "$output" == *"Set-VMMemory -VMName podman4ai -DynamicMemoryEnabled \$false"*"p4a machine start"* ]]
}

@test "status prints no dynamic-memory warning when it's off" {
  machines "podman4ai hyperv running"
  dynamic_memory False
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" != *"dynamic memory"* ]]
  [[ "$output" != *"warning"* ]]
  [ -n "$(powershell_calls_with "Get-VMMemory -VMName podman4ai")" ]
}

@test "status warns that it couldn't check dynamic memory, and still succeeds, when Hyper-V can't say" {
  machines "podman4ai hyperv stopped"
  fake_powershell "Get-VMMemory" --exit 1 \
    --stderr "Get-VMMemory : You do not have the required permission to complete this task."
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman4ai: stopped"* ]]
  [[ "$output" == *"warning: couldn't check"*"dynamic memory"* ]]
}

@test "status treats an unexpected answer from Hyper-V as unchecked" {
  machines "podman4ai hyperv stopped"
  dynamic_memory ""
  run p4a machine status
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: couldn't check"*"dynamic memory"* ]]
}

@test "status doesn't ask Hyper-V about a Sandbox machine that doesn't exist" {
  machines
  run p4a machine status
  [ "$status" -eq 0 ]
  [ -z "$(powershell_calls)" ]
}

@test "start makes no Hyper-V memory call" {
  machines "podman4ai hyperv stopped"
  dynamic_memory True
  run p4a machine start
  [ "$status" -eq 0 ]
  [ -n "$(podman_calls_starting "machine start")" ]
  [ -z "$(powershell_calls)" ]
}

@test "status says a running Sandbox machine is unusable when Podman doesn't answer, and how to fix it" {
  machines "podman4ai hyperv running"
  podman_not_answering
  run p4a machine status
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman4ai"*"Podman"*"doesn't answer"* ]]
  [[ "$output" == *"p4a machine stop"*"p4a machine start"* ]]
}


@test "start on a running Sandbox machine whose Podman doesn't answer says to stop it first" {
  machines "podman4ai hyperv running"
  podman_not_answering
  run p4a machine start
  [ "$status" -eq 1 ]
  [[ "$output" != *"already running"* ]]
  [[ "$output" == *"p4a machine stop"*"p4a machine start"* ]]
  [ -z "$(podman_calls_starting "machine start")" ]
}
