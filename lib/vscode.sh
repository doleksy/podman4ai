# shellcheck shell=bash
# p4a code: VS Code attached to a project's Sandbox (ADR 0007).
#
# VS Code's Dev Containers extension, attached to a container, answers
# requests from inside it with Windows' own git credentials, whatever its
# settings say, and passes the Windows ssh-agent through. So p4a code
# opens VS Code with Windows' git config switched off (no credential
# helper, so those requests come back empty), without SSH_AUTH_SOCK, and
# only once VS Code's settings stop it setting up anything else.
#
# It's a VS Code of its own: its own data folder (settings, sign-ins,
# windows to restore) and extensions folder, in the Host settings, apart
# from the developer's everyday VS Code. So no everyday sign-in (GitHub's,
# say) or extension reaches a Sandbox, and the everyday VS Code never
# opens a Sandbox without these protections.

# The VS Code settings p4a code needs, one per line: the setting, a regex
# for the values it accepts (in settings.json, without spaces), and the
# value to write or suggest. dockerPath may also be a full path to podman.
# VS Code's default for defaultExtensionsIfInstalledLocally installs the
# GitHub Copilot and Pull Requests extensions in every container.
P4A_VSCODE_REQUIRED_SETTINGS='dev.containers.dockerPath "([^"]*[/\\])?podman(\.exe)?" "podman"
dev.containers.copyGitConfig false false
dev.containers.gitCredentialHelperConfigLocation "none" "none"
dev.containers.dockerCredentialHelper false false
remote.defaultExtensionsIfInstalledLocally \[\] []'
# The extension p4a code's VS Code attaches with.
P4A_VSCODE_DEV_CONTAINERS=ms-vscode-remote.remote-containers

# Where p4a code's VS Code keeps its data and its extensions.
_p4a_vscode_dir() { echo "$(p4a_config_dir)/vscode"; }
_p4a_vscode_settings_file() { echo "$(_p4a_vscode_dir)/data/User/settings.json"; }

# p4a code PROJECT
p4a_code() {
  [[ $# -eq 1 ]] || p4a_usage_error "code needs one project name" "p4a --help"
  local project=$1
  _p4a_require_project "$project"
  command -v code >/dev/null 2>&1 \
    || p4a_die "VS Code's 'code' command isn't on PATH" \
      "install VS Code with its 'Add to PATH' option, then open a new Git Bash"

  # Without these, code's arguments aren't converted from Git Bash paths.
  local vscode_dirs=(
    --user-data-dir "$(p4a_native_path "$(_p4a_vscode_dir)/data")"
    --extensions-dir "$(p4a_native_path "$(_p4a_vscode_dir)/extensions")"
  )
  _p4a_set_up_vscode "${vscode_dirs[@]}"
  _p4a_require_vscode_settings
  p4a_require_running_sandbox_machine
  if [[ "$(_p4a_sandbox_running "$project")" != true ]]; then
    p4a_note "starting $project"
    _p4a_start_existing_project "$project"
  fi
  _p4a_warn_about_ssh_agent

  # An empty file for git's global config: with it, and no system config,
  # Windows git has no credential helper while VS Code runs.
  local no_gitconfig
  no_gitconfig="$(p4a_config_dir)/empty.gitconfig"
  : > "$no_gitconfig"

  local source_dir hex
  source_dir="$(_p4a_source_dir "$project")"
  # The plain container name: Podman finds none named "/name", the Docker
  # form VS Code's own attach menu uses.
  hex="$(printf '{"containerName":"%s"}' "$(_p4a_sandbox_name "$project")" | od -An -tx1 | tr -d ' \n')"
  # No ssh-agent, and no password prompt program (Git Bash sets
  # SSH_ASKPASS), so a credential request from the Sandbox can't show a
  # prompt on Windows either.
  env -u SSH_AUTH_SOCK -u SSH_ASKPASS -u GIT_ASKPASS MSYS_NO_PATHCONV=1 \
    CONTAINER_CONNECTION="$P4A_MACHINE" CONTAINERS_MACHINE_PROVIDER="$P4A_PROVIDER" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$(p4a_native_path "$no_gitconfig")" \
    code "${vscode_dirs[@]}" --new-window --folder-uri "vscode-remote://attached-container+$hex$source_dir"
  echo "Opened VS Code attached to $project's Sandbox, in $source_dir."
}

# _p4a_set_up_vscode VSCODE_DIR_OPTION...
# The first time, write p4a code's VS Code settings and install Dev
# Containers in it. Later, leave the settings as the developer changed
# them (_p4a_require_vscode_settings checks them).
_p4a_set_up_vscode() {
  local settings key accepted suggested lines=()
  settings="$(_p4a_vscode_settings_file)"
  mkdir -p "$(dirname "$settings")" "$(_p4a_vscode_dir)/extensions"
  if [[ ! -s $settings ]]; then
    while read -r key accepted suggested; do
      lines+=("  \"$key\": $suggested")
    done <<< "$P4A_VSCODE_REQUIRED_SETTINGS"
    # VS Code allows the trailing comma.
    {
      echo "{"
      echo "  // Written by p4a code, which checks these on every run (docs/vscode.md)."
      printf '%s,\n' "${lines[@]}"
      echo "}"
    } > "$settings"
  fi
  local installed=("$(_p4a_vscode_dir)/extensions/$P4A_VSCODE_DEV_CONTAINERS"-*)
  [[ -e ${installed[0]} ]] && return 0
  p4a_note "installing Dev Containers in p4a code's VS Code"
  MSYS_NO_PATHCONV=1 code "$@" --install-extension "$P4A_VSCODE_DEV_CONTAINERS" >/dev/null \
    || p4a_die "couldn't install Dev Containers ($P4A_VSCODE_DEV_CONTAINERS) in p4a code's VS Code (see its message above)" \
      "check VS Code can reach its marketplace, then try again"
}

# Exit, naming them, unless p4a code's VS Code settings have every setting
# it needs. Spacing doesn't matter, commented-out lines don't count, and
# where a setting appears twice the last one counts, as in VS Code.
_p4a_require_vscode_settings() {
  local file text="" key accepted suggested value missing=()
  file="$(_p4a_vscode_settings_file)"
  [[ -r $file ]] && text="$(grep -vE '^[[:space:]]*//' "$file" | tr -d ' \t\r\n')"
  while read -r key accepted suggested; do
    value="$(grep -oE "\"${key//./\\.}\":[^,}]*" <<< "$text" | tail -1)" || true
    value="${value#*:}"
    [[ $value =~ ^($accepted)$ ]] || missing+=("\"$key\": $suggested")
  done <<< "$P4A_VSCODE_REQUIRED_SETTINGS"
  (( ${#missing[@]} == 0 )) && return 0
  {
    echo "p4a: p4a code's VS Code settings would let an attached Sandbox use Windows' git or Docker credentials or your extensions, or not find the Sandbox machine. Add these to $file:"
    printf '  %s,\n' "${missing[@]}"
    echo "  fix: add the lines (or delete the file, and p4a code writes it again), then try again"
  } >&2
  exit 1
}

# Warn if the Windows OpenSSH agent is running: VS Code passes it into
# every container it attaches to, and nothing turns that off.
_p4a_warn_about_ssh_agent() {
  local status
  status="$(p4a_powershell "(Get-Service ssh-agent -ErrorAction SilentlyContinue).Status" 2>/dev/null)" || return 0
  [[ ${status//$'\r'/} == Running ]] || return 0
  p4a_note "the Windows ssh-agent is running, and VS Code passes it into the Sandbox, so an Agent could use your SSH keys while VS Code is attached. To stop it, run 'Stop-Service ssh-agent' in an admin PowerShell."
}
