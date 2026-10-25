#!/usr/bin/env bats
# Properties every Podman call p4a makes must have.

load helpers

@test "every Podman call p4a makes selects the Hyper-V provider" {
  machines
  p4a machine create
  machines "podman4ai hyperv stopped"
  p4a machine start
  p4a machine status
  machines "podman4ai hyperv running"
  p4a machine stop
  p4a podman ps

  local calls
  calls="$(podman_calls)"
  [[ "$calls" == *"machine list"* ]]
  [[ "$calls" == *"machine init"* ]]
  [[ "$calls" == *"machine start"* ]]
  [[ "$calls" == *"machine stop"* ]]
  [[ "$calls" == *" ps"* ]]
  [ -z "$(podman_call_env CONTAINERS_MACHINE_PROVIDER | grep -vx hyperv)" ]
}

@test "p4a podman runs a podman command against the Sandbox machine" {
  run p4a podman ps -a
  [ "$status" -eq 0 ]
  [ "$(podman_calls)" = "--connection podman4ai ps -a" ]
}

@test "a Unix-style path argument reaches Podman unchanged under Git Bash" {
  run p4a podman run --rm -v proj-src:/workspace -w /workspace img ls /workspace
  [ "$status" -eq 0 ]
  [ "$(podman_call_args_json 1)" = '["--connection","podman4ai","run","--rm","-v","proj-src:/workspace","-w","/workspace","img","ls","/workspace"]' ]
}

@test "a missing podman is reported with how to install it" {
  PATH="$P4A_REPO/bin:/usr/bin:/bin"
  run p4a machine status
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman not found"* ]]
  [[ "$output" == *"install Podman"* ]]
}
