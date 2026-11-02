#!/usr/bin/env bats
# p4a code: opening VS Code attached to a project's Sandbox, without
# handing the Sandbox any Windows credentials.

load project-helpers

# VS Code's user settings, with the settings p4a code needs.
SAFE_SETTINGS='{
  // Dev Containers, for podman4ai
  "dev.containers.dockerPath": "podman",
  "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "dev.containers.dockerCredentialHelper": false,
  "editor.fontSize": 14
}'

# What the stand-in code recorded.
code_calls() {
  cat "$FAKE_CODE_DIR/calls" 2>/dev/null || true
}

# hello-world exists and is running, VS Code has SETTINGS (the safe ones by
# default), and the Windows ssh-agent service is stopped.
hello_world_for_code() {
  export FAKE_CODE_DIR="$BATS_TEST_TMPDIR/code"
  mkdir -p "$FAKE_CODE_DIR"
  export P4A_VSCODE_SETTINGS="$BATS_TEST_TMPDIR/vscode-settings.json"
  printf '%s\n' "${1:-$SAFE_SETTINGS}" > "$P4A_VSCODE_SETTINGS"
  hello_world_exists
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout true
  fake_powershell "Get-Service ssh-agent" --stdout Stopped
}

@test "code opens VS Code attached to the project's Sandbox, in its source folder" {
  hello_world_for_code
  run p4a code hello-world
  [ "$status" -eq 0 ]
  local hex
  hex="$(printf '%s' '{"containerName":"/podman4ai-hello-world"}' | od -An -tx1 | tr -d ' \n')"
  code_calls | has_line "--folder-uri"
  code_calls | has_line "vscode-remote://attached-container+$hex/workspace/hello-world"
  # VS Code's podman reaches the Sandbox machine, not the default one.
  code_calls | has_line "env CONTAINER_CONNECTION=podman4ai"
}

@test "code opens VS Code with no Windows git config or ssh-agent, so the Sandbox can't get Windows credentials through it" {
  hello_world_for_code
  SSH_AUTH_SOCK=/tmp/ssh-agent.sock run p4a code hello-world
  [ "$status" -eq 0 ]
  code_calls | has_line "env GIT_CONFIG_NOSYSTEM=1"
  code_calls | has_line "git config global: empty file"
  code_calls | has_line "env SSH_AUTH_SOCK=<unset>"
}

@test "code refuses, naming them, until VS Code has the settings that keep Windows credentials out" {
  hello_world_for_code '{
  "dev.containers.dockerPath": "podman",
  "dev.containers.copyGitConfig": true,
  "editor.fontSize": 14
}'
  run p4a code hello-world
  [ "$status" -eq 1 ]
  [ -z "$(code_calls)" ]
  [[ "$output" == *'"dev.containers.copyGitConfig": false'* ]]
  [[ "$output" == *'"dev.containers.gitCredentialHelperConfigLocation": "none"'* ]]
  [[ "$output" == *'"dev.containers.dockerCredentialHelper": false'* ]]
  [[ "$output" != *'"dev.containers.dockerPath": "podman"'* ]]
  [[ "$output" == *"$P4A_VSCODE_SETTINGS"* ]]

  # Spacing doesn't matter.
  printf '{"dev.containers.dockerPath":"podman","dev.containers.copyGitConfig":false,\n"dev.containers.gitCredentialHelperConfigLocation" :  "none", "dev.containers.dockerCredentialHelper":false}\n' \
    > "$P4A_VSCODE_SETTINGS"
  run p4a code hello-world
  [ "$status" -eq 0 ]
}

@test "code warns when the Windows ssh-agent is running, which VS Code passes into the Sandbox" {
  hello_world_for_code
  fake_powershell "Get-Service ssh-agent" --stdout Running
  run p4a code hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh-agent"* ]]
  [[ "$output" == *"Stop-Service ssh-agent"* ]]
}
