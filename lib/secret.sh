# shellcheck shell=bash
# p4a secret: the Agent token and Project secrets, stored as Podman secrets in
# the Sandbox machine and mounted into Sandboxes as files.
#
# A value only ever travels through a hidden prompt and a pipe to Podman's
# stdin: never a command line, an environment definition or an image.

P4A_AGENT_TOKEN_SECRET=podman4ai-agent-token

# A Project secret NAME of PROJECT is the Podman secret
# podman4ai.<project>.<name>, labelled with both. The secret module finds a
# project's secrets by the project label, never by parsing secret names.
# The name is unique anyway: a secret name has no ".", so the last "."
# divides project from name, and the "." after podman4ai keeps it apart
# from the Agent token and legacy Repo tokens.
P4A_SECRET_PROJECT_LABEL=podman4ai.project
P4A_SECRET_NAME_LABEL=podman4ai.secret-name
P4A_SECRET_NAME_PATTERN='^[a-z0-9][a-z0-9-]*$'
p4a_project_secret() { echo "podman4ai.$1.$2"; }
# A Repo token stored before Project secrets existed: unlabelled, and
# still that project's repo-token until a labelled one is stored.
_p4a_legacy_repo_token_secret() { echo "podman4ai-$1-repo-token"; }

# Where the secrets appear in a Sandbox: /run/secrets/<name>, readable only
# by the Base image's user (uid 1000). The Repo token is the Project secret
# named repo-token.
P4A_AGENT_TOKEN_FILE=agent-token
P4A_REPO_TOKEN_NAME=repo-token

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
Usage: p4a secret set agent-token
       p4a secret set <name> <project>

Store a secret in the Sandbox machine. The value is read from a hidden
prompt, so it never appears on a command line or in shell history.
Storing a secret again replaces its value.

Secrets:
  agent-token             the Agent token every Sandbox uses to sign in to
                          Claude (create one with 'claude setup-token').
                          The name is reserved: it takes no project.
  <name> <project>        a Project secret: a value only that project's
                          Sandbox gets, as the read-only file
                          /run/secrets/<name> (for example
                          'p4a secret set mouser-api-key hello-world').
                          A name is lower-case letters, digits and hyphens.
                          Store it before or after 'p4a new'.
  repo-token <project>    the Project secret git and gh use: a fine-grained
                          token from GitHub for that project's one
                          repository. It needs Contents, Pull requests and
                          Issues, each Read and write. The README's "Repo
                          token permissions" lists the recommended and
                          optional permissions. Set it before 'p4a new' to
                          clone a private repository.

A Sandbox gets copies of its secrets when it's created, so an existing one
gets a new or changed secret at its next 'p4a stop', then 'p4a start',
which recreates the Sandbox (keeping its source and Claude config).
p4a start never recreates a running Sandbox.
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
    "") p4a_usage_error "secret set needs a secret name" "p4a secret --help" ;;
    *)
      [[ $name =~ $P4A_SECRET_NAME_PATTERN ]] \
        || p4a_usage_error "'$name' isn't a secret name: use lower-case letters, digits and hyphens, starting with a letter or digit" "p4a secret --help"
      local project="${2:-}"
      [[ $# -eq 2 && $project =~ $P4A_PROJECT_NAME_PATTERN ]] \
        || p4a_usage_error "secret set $name needs one project name (the repository's name in lower case)" "p4a secret --help"
      local description="secret $name for $project"
      [[ $name != "$P4A_REPO_TOKEN_NAME" ]] || description="Repo token for $project"
      p4a_require_running_sandbox_machine
      _p4a_store_project_secret "$project" "$name" "$description"
      echo "Stored the $description."
      if [[ -f "$(_p4a_projects_dir)/$project.conf" ]]; then
        echo "Its Sandbox uses it once restarted: p4a stop $project, then p4a start $project."
      else
        echo "p4a new will use it for the project $project."
      fi
      ;;
  esac
}

# _p4a_store_secret SECRET DESCRIPTION [OPTION...]
# Read a value from a hidden prompt and store it as SECRET, replacing any
# value it had, with the secret create OPTIONs (its labels). Podman gives
# the replaced secret a new ID, and containers keep the copy they got when
# created: p4a start recreates them.
_p4a_store_secret() {
  local secret=$1 description=$2 value
  shift 2
  IFS= read -rsp "Paste the $description (input hidden): " value || true
  [[ -t 0 ]] && echo >&2
  value="${value//[[:space:]]/}"
  [[ -n $value ]] || p4a_die "no $description entered, so nothing was stored" "run the command again and paste the value"
  # printf is a shell builtin, so the value is never on a command line.
  printf %s "$value" | p4a_sandbox_podman secret create --replace "$@" "$secret" - >/dev/null \
    || p4a_die "couldn't store the $description in the Sandbox machine (see podman's message above)" \
      "check the Sandbox machine with 'p4a machine status'"
}

# _p4a_store_project_secret PROJECT NAME DESCRIPTION
# Store PROJECT's Project secret NAME as _p4a_store_secret does, labelled
# with its project and name so p4a_project_secrets finds it.
_p4a_store_project_secret() {
  _p4a_store_secret "$(p4a_project_secret "$1" "$2")" "$3" \
    --label "$P4A_SECRET_PROJECT_LABEL=$1" --label "$P4A_SECRET_NAME_LABEL=$2"
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

# Print PROJECT's Project secrets, one "SECRET FILE" line each: the Podman
# secret, and the file name it appears as in the Sandbox (the Project
# secret's name). Found by label, so never another project's, whatever the
# names. An unlabelled legacy Repo token counts as the repo-token unless a
# labelled one exists. Exit if Podman can't say, so nothing acts on a list
# that's wrongly empty.
p4a_project_secrets() {
  local project=$1 secret_list secrets=() secret_names="" secret name legacy
  local -A seen=()
  secret_list="$(p4a_sandbox_podman secret ls --filter "label=$P4A_SECRET_PROJECT_LABEL=$project" \
      --format '{{.Name}}' < /dev/null)" \
    || p4a_die "couldn't list the secrets of $project (see podman's message above)" \
      "check the Sandbox machine with 'p4a machine status', then try again"
  mapfile -t secrets < <(grep -v '^$' <<< "$secret_list" | sort)
  # Each secret's Project secret name, from its label: "SECRET NAME" lines.
  if (( ${#secrets[@]} )); then
    secret_names="$(p4a_sandbox_podman secret inspect \
        --format "{{.Spec.Name}} {{index .Spec.Labels \"$P4A_SECRET_NAME_LABEL\"}}" "${secrets[@]}" < /dev/null)" \
      || p4a_die "couldn't read the secrets of $project (see podman's message above)" \
        "check the Sandbox machine with 'p4a machine status', then try again"
  fi
  # The name becomes the file name, so only a valid one, only once, and
  # never the Agent token's.
  while read -r secret name; do
    [[ $name =~ $P4A_SECRET_NAME_PATTERN && $name != "$P4A_AGENT_TOKEN_FILE" && -z ${seen[$name]:-} ]] || continue
    seen[$name]=1
    echo "$secret $name"
  done <<< "$secret_names"
  legacy="$(_p4a_legacy_repo_token_secret "$project")"
  if [[ -z ${seen[$P4A_REPO_TOKEN_NAME]:-} ]] && p4a_secret_exists "$legacy"; then
    echo "$legacy $P4A_REPO_TOKEN_NAME"
  fi
}

# Exit with how to set it unless the Agent token is stored.
p4a_require_agent_token() {
  p4a_secret_exists "$P4A_AGENT_TOKEN_SECRET" \
    || p4a_die "there's no Agent token, so Sandboxes can't sign in to Claude" \
      "create one on the Host with 'claude setup-token', then store it with 'p4a secret set agent-token'"
}

