# shellcheck shell=bash
# p4a secret: the Agent token and Repo tokens, stored as Podman secrets in
# the Sandbox machine and mounted into Sandboxes as files.
#
# A value only ever travels through a hidden prompt and a pipe to Podman's
# stdin: never a command line, an environment definition or an image.

P4A_AGENT_TOKEN_SECRET=podman4ai-agent-token
p4a_repo_token_secret() { echo "podman4ai-$1-repo-token"; }

# Where the tokens appear in a Sandbox: /run/secrets/<name>, readable only
# by the Base image's user (uid 1000).
P4A_AGENT_TOKEN_FILE=agent-token
P4A_REPO_TOKEN_FILE=repo-token

p4a_secret() {
  local command="${1:-}"
  case $command in
    "" | -h | --help | help) p4a_secret_usage ;;
    set) shift; _p4a_secret_set "$@" ;;
    *) p4a_usage_error "unknown command 'secret $command'" "p4a secret --help" ;;
  esac
}

p4a_secret_usage() {
  cat <<'EOF'
Usage: p4a secret set <name> [project]

Store a secret in the Sandbox machine. The value is read from a hidden
prompt, so it never appears on a command line or in shell history.

Secrets:
  agent-token             the Agent token every Sandbox uses to sign in to
                          Claude (create one with 'claude setup-token')
  repo-token <project>    a fine-grained token from GitHub for that project's one
                          repository (contents and pull requests: read and
                          write). Set it before 'p4a new' to clone a private
                          repository.

Existing Sandboxes get a new value at their next 'p4a stop', then
'p4a start', which recreates the Sandbox (keeping its source and Claude
config).
EOF
}

_p4a_secret_set() {
  local name="${1:-}"
  case $name in
    agent-token)
      [[ $# -eq 1 ]] || p4a_usage_error "secret set agent-token takes no other arguments" "p4a secret --help"
      p4a_require_running_sandbox_machine
      _p4a_store_secret "$P4A_AGENT_TOKEN_SECRET" "Agent token"
      echo "Stored the Agent token."
      echo "Existing Sandboxes get it when restarted: p4a stop <project>, then p4a start <project>."
      ;;
    repo-token)
      local project="${2:-}"
      [[ $# -eq 2 && $project =~ $P4A_PROJECT_NAME_PATTERN ]] \
        || p4a_usage_error "secret set repo-token needs one project name (the repository's name in lower case)" "p4a secret --help"
      p4a_require_running_sandbox_machine
      _p4a_store_secret "$(p4a_repo_token_secret "$project")" "Repo token for $project"
      echo "Stored the Repo token for $project."
      if [[ -f "$(_p4a_projects_dir)/$project.conf" ]]; then
        echo "Its Sandbox uses it once restarted: p4a stop $project, then p4a start $project."
      else
        echo "p4a new will use it for the project $project."
      fi
      ;;
    *) p4a_usage_error "unknown secret '$name'" "p4a secret --help" ;;
  esac
}

# _p4a_store_secret SECRET DESCRIPTION
# Read a value from a hidden prompt and store it as SECRET, replacing any
# value it had. Podman gives the replaced secret a new ID, and containers
# keep the copy they got when created: p4a start recreates them.
_p4a_store_secret() {
  local value
  IFS= read -rsp "Paste the $2 (input hidden): " value || true
  [[ -t 0 ]] && echo >&2
  value="${value//[[:space:]]/}"
  [[ -n $value ]] || p4a_die "no $2 entered, so nothing was stored" "run the command again and paste the value"
  # printf is a shell builtin, so the value is never on a command line.
  printf %s "$value" | p4a_sandbox_podman secret create --replace "$1" - >/dev/null \
    || p4a_die "couldn't store the $2 in the Sandbox machine (see podman's message above)" \
      "check the Sandbox machine with 'p4a machine status'"
}

# Succeed if the secret NAME exists in the Sandbox machine, fail if not.
# Exit if Podman can't tell.
p4a_secret_exists() {
  local status=0
  p4a_sandbox_podman secret exists "$1" || status=$?
  case $status in
    0 | 1) return "$status" ;;
    *) p4a_die "couldn't check whether the secret $1 exists (podman exited with $status)" \
         "check the Sandbox machine with 'p4a machine status'" ;;
  esac
}

# Exit with how to set it unless the Agent token is stored.
p4a_require_agent_token() {
  p4a_secret_exists "$P4A_AGENT_TOKEN_SECRET" \
    || p4a_die "there's no Agent token, so Sandboxes can't sign in to Claude" \
      "create one on the Host with 'claude setup-token', then store it with 'p4a secret set agent-token'"
}

