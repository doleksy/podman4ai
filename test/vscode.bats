#!/usr/bin/env bats
# p4a code: opening VS Code attached to a project's Sandbox, without
# handing the Sandbox any Windows credentials.

load project-helpers

# Settings with everything p4a code needs.
SAFE_SETTINGS='{
  // Dev Containers, for podman4ai
  "dev.containers.dockerPath": "podman",
  "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "dev.containers.dockerCredentialHelper": false,
  "dev.containers.forwardWSLServices": false,
  "remote.defaultExtensionsIfInstalledLocally": [],
  "editor.fontSize": 14
}'

# Where p4a code keeps the VS Code it opens: its own data and extensions,
# apart from the developer's everyday VS Code.
vscode_dir() { echo "$P4A_CONFIG_DIR/vscode"; }
vscode_settings() { echo "$(vscode_dir)/data/User/settings.json"; }

# What the stand-in code recorded.
code_calls() {
  cat "$FAKE_CODE_DIR/calls" 2>/dev/null || true
}

# hello-world exists and is running, and the Windows ssh-agent service is
# stopped. p4a code's VS Code has SETTINGS (the safe ones by default; with
# "none", no settings file yet) and Dev Containers installed.
hello_world_for_code() {
  export FAKE_CODE_DIR="$BATS_TEST_TMPDIR/code"
  mkdir -p "$FAKE_CODE_DIR"
  if [[ ${1:-} != none ]]; then
    mkdir -p "$(dirname "$(vscode_settings)")" "$(vscode_dir)/extensions/ms-vscode-remote.remote-containers-0.469.0"
    printf '%s\n' "${1:-$SAFE_SETTINGS}" > "$(vscode_settings)"
  fi
  hello_world_exists
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout true
  fake_powershell "Get-Service ssh-agent" --stdout Stopped
}

@test "code opens VS Code attached to the project's Sandbox, in its source folder" {
  hello_world_for_code
  run p4a code hello-world
  [ "$status" -eq 0 ]
  local hex
  # The plain name: Podman finds no container named "/podman4ai-hello-world"
  # (Docker's form, which VS Code's own attach menu uses).
  hex="$(printf '%s' '{"containerName":"podman4ai-hello-world"}' | od -An -tx1 | tr -d ' \n')"
  code_calls | has_line "--folder-uri"
  code_calls | has_line "vscode-remote://attached-container+$hex/workspace/hello-world"
  # VS Code's podman reaches the Sandbox machine, not the default one.
  code_calls | has_line "env CONTAINER_CONNECTION=podman4ai"
}

@test "code opens VS Code with no Windows git config, ssh-agent or password prompt, so the Sandbox can't get Windows credentials through it" {
  hello_world_for_code
  # Git Bash sets SSH_ASKPASS: with it, a credential request from the
  # Sandbox would pop up a password prompt on Windows.
  SSH_AUTH_SOCK=/tmp/ssh-agent.sock SSH_ASKPASS=/c/git-askpass.exe GIT_ASKPASS=/c/git-askpass.exe \
    run p4a code hello-world
  [ "$status" -eq 0 ]
  code_calls | has_line "env GIT_CONFIG_NOSYSTEM=1"
  code_calls | has_line "git config global: empty file"
  code_calls | has_line "env SSH_AUTH_SOCK=<unset>"
  code_calls | has_line "env SSH_ASKPASS=<unset>"
  code_calls | has_line "env GIT_ASKPASS=<unset>"
}

@test "code refuses, naming them, until VS Code has the settings that keep Windows and WSL credentials out" {
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
  [[ "$output" == *'"dev.containers.forwardWSLServices": false'* ]]
  [[ "$output" != *'"dev.containers.dockerPath": "podman"'* ]]
  [[ "$output" == *'"remote.defaultExtensionsIfInstalledLocally": []'* ]]
  [[ "$output" == *"$(vscode_settings)"* ]]

  # Spacing doesn't matter.
  printf '{"dev.containers.dockerPath":"podman","dev.containers.copyGitConfig":false,\n"dev.containers.gitCredentialHelperConfigLocation" :  "none", "dev.containers.dockerCredentialHelper":false, "dev.containers.forwardWSLServices": false, "remote.defaultExtensionsIfInstalledLocally": [ ]}\n' \
    > "$(vscode_settings)"
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

@test "code's settings check skips commented-out lines, takes the last of a repeated setting, and accepts a full path to podman" {
  hello_world_for_code '{
  "dev.containers.dockerPath": "C:\Program Files\RedHat\Podman\podman.exe",
  // "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "dev.containers.gitCredentialHelperConfigLocation": "global",
  "dev.containers.dockerCredentialHelper": false
}'
  run p4a code hello-world
  [ "$status" -eq 1 ]
  [ -z "$(code_calls)" ]
  [[ "$output" == *'"dev.containers.copyGitConfig": false'* ]]
  [[ "$output" == *'"dev.containers.gitCredentialHelperConfigLocation": "none"'* ]]
  [[ "$output" != *'"dev.containers.dockerPath"'* ]]
  [[ "$output" != *'"dev.containers.dockerCredentialHelper"'* ]]
}

@test "code opens a VS Code of its own, with its own settings, extensions and sign-ins, never the everyday one" {
  hello_world_for_code
  run p4a code hello-world
  [ "$status" -eq 0 ]
  code_calls | has_line "--user-data-dir"
  code_calls | has_line "$(_native_path "$(vscode_dir)/data")"
  code_calls | has_line "--extensions-dir"
  code_calls | has_line "$(_native_path "$(vscode_dir)/extensions")"
}

@test "the first code writes its VS Code's settings and installs Dev Containers in it, once" {
  hello_world_for_code none
  run p4a code hello-world
  [ "$status" -eq 0 ]
  local settings
  settings="$(tr -d ' \n' < "$(vscode_settings)")"
  [[ $settings == *'"dev.containers.dockerPath":"podman"'* ]]
  [[ $settings == *'"dev.containers.copyGitConfig":false'* ]]
  [[ $settings == *'"dev.containers.gitCredentialHelperConfigLocation":"none"'* ]]
  [[ $settings == *'"dev.containers.dockerCredentialHelper":false'* ]]
  [[ $settings == *'"dev.containers.forwardWSLServices":false'* ]]
  # VS Code's default would install the GitHub extensions in every Sandbox.
  [[ $settings == *'"remote.defaultExtensionsIfInstalledLocally":[]'* ]]
  [ "$(code_calls | grep -c -- '--install-extension')" -eq 1 ]
  code_calls | has_line "ms-vscode-remote.remote-containers"

  # The developer's own changes are kept, and Dev Containers isn't installed again.
  printf '{\n  "workbench.colorTheme": "Default Dark Modern",\n%s\n' "$(tail -n +2 "$(vscode_settings)")" > "$(vscode_settings)"
  run p4a code hello-world
  [ "$status" -eq 0 ]
  grep -q colorTheme "$(vscode_settings)"
  [ "$(code_calls | grep -c -- '--install-extension')" -eq 1 ]
}
