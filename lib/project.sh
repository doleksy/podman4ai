# shellcheck shell=bash
# A project's Sandbox: p4a new, start, stop and shell.
#
# Each project has its own Project volume (source), Claude config volume,
# internal network with no route out, Egress proxy and Sandbox. Its Host
# settings live in the Host user config folder, outside every repo
# (ADR 0002).

# Default limits for every Sandbox.
P4A_SANDBOX_MEMORY=4g
P4A_SANDBOX_CPUS=4
P4A_SANDBOX_PIDS=4096

# The hardening every project container (Sandbox and Egress proxy) gets.
# Podman's default seccomp and SELinux protections stay on because nothing
# here turns them off.
P4A_CONTAINER_HARDENING=(
  --cap-drop=all
  --security-opt=no-new-privileges
)
# The Sandbox also runs as the Base image's non-root user, agent, whose
# uid is set in images/base/Containerfile.
P4A_SANDBOX_UID=1000
# The Sandbox's hardening: the containers' own, plus running as agent.
P4A_SANDBOX_HARDENING=("${P4A_CONTAINER_HARDENING[@]}" --user=agent)

# Where the Project volume and Claude config volume appear in the Sandbox.
P4A_PROJECT_VOLUME_PATH=/workspace
P4A_CLAUDE_CONFIG_PATH=/home/agent/.claude

# Each project's network is 10.89.N.0/24 for an N in this range, with its
# Egress proxy at .2. (The image build uses 10.89.200.0/24.)
P4A_PROJECT_SUBNET_FIRST=1
P4A_PROJECT_SUBNET_LAST=199
# The name the Sandbox reaches its Egress proxy by, and the proxy's address.
P4A_PROXY_HOST=egress-proxy
P4A_PROXY_URL=http://$P4A_PROXY_HOST:8888

# Where per-project Host settings live.
p4a_config_dir() {
  if [[ -n ${P4A_CONFIG_DIR:-} ]]; then
    echo "$P4A_CONFIG_DIR"
  elif [[ -n ${APPDATA:-} ]]; then
    echo "$(p4a_unix_path "$APPDATA")/podman4ai"
  else
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/podman4ai"
  fi
}

_p4a_projects_dir() {
  echo "$(p4a_config_dir)/projects"
}

# Project names: what p4a new makes from a repository's name.
P4A_PROJECT_NAME_PATTERN='^[a-z0-9][a-z0-9._-]*$'

# The project name for owner/REPO: the repository's name in lower case.
_p4a_project_name() {
  local name="${1#*/}"
  echo "${name,,}"
}

# The Podman names of PROJECT's parts.
_p4a_sandbox_name() { echo "podman4ai-$1"; }
_p4a_proxy_name() { echo "podman4ai-$1-proxy"; }
_p4a_network_name() { echo "podman4ai-$1"; }
_p4a_project_volume_name() { echo "podman4ai-$1-source"; }
_p4a_claude_volume_name() { echo "podman4ai-$1-claude"; }

# _p4a_project_setting PROJECT KEY
# Print one value from PROJECT's settings file (lines of key=value).
_p4a_project_setting() {
  local key value
  while IFS='=' read -r key value; do
    [[ $key == "$2" ]] && { echo "$value"; return 0; }
  done < "$(_p4a_projects_dir)/$1.conf"
  return 1
}

# Print the third number of the first project subnet no project uses yet.
_p4a_free_subnet() {
  local used=" " conf subnet n
  for conf in "$(_p4a_projects_dir)"/*.conf; do
    [[ -e $conf ]] || continue
    subnet="$(_p4a_project_setting "$(basename "$conf" .conf)" subnet || true)"
    [[ $subnet =~ ^10\.89\.([0-9]+)\.0/24$ ]] && used+="${BASH_REMATCH[1]} "
  done
  for (( n = P4A_PROJECT_SUBNET_FIRST; n <= P4A_PROJECT_SUBNET_LAST; n++ )); do
    [[ $used == *" $n "* ]] || { echo "$n"; return 0; }
  done
  p4a_die "every project network address range is in use" "remove a project you no longer need"
}

p4a_new() {
  local repo="${1:-}"
  [[ $# -eq 1 && $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] \
    || p4a_usage_error "new needs one GitHub repository as owner/repo" "p4a --help"
  local project
  project="$(_p4a_project_name "$repo")"
  [[ $project =~ $P4A_PROJECT_NAME_PATTERN ]] \
    || p4a_usage_error "'$repo' doesn't name a GitHub repository p4a can use" "p4a --help"

  local dir conf
  dir="$(_p4a_projects_dir)"
  conf="$dir/$project.conf"
  [[ ! -e $conf ]] \
    || p4a_die "the project $project already exists" "start it with 'p4a start $project'"

  p4a_require_running_sandbox_machine
  p4a_require_agent_token
  # Check the developer's git identity now, before creating anything.
  local identity=()
  _p4a_git_identity identity

  local network proxy sandbox project_volume claude_volume
  network="$(_p4a_network_name "$project")"
  proxy="$(_p4a_proxy_name "$project")"
  sandbox="$(_p4a_sandbox_name "$project")"
  project_volume="$(_p4a_project_volume_name "$project")"
  claude_volume="$(_p4a_claude_volume_name "$project")"

  # Parts with these names may be left from an earlier project of the same
  # name, possibly with unpushed work. Never reuse or remove them.
  local part kind name status
  for part in volume:"$project_volume" volume:"$claude_volume" network:"$network" \
      container:"$proxy" container:"$sandbox"; do
    kind="${part%%:*}" name="${part#*:}" status=0
    p4a_sandbox_podman "$kind" exists "$name" || status=$?
    case $status in
      1) ;;
      0) p4a_die "can't create the project $project: the $kind $name already exists in the Sandbox machine" \
           "if nothing in it is needed, remove it with 'p4a podman $kind rm $name', then run 'p4a new $repo' again" ;;
      *) p4a_die "couldn't check whether the $kind $name exists (podman exited with $status)" \
           "check the Sandbox machine with 'p4a machine status', then run 'p4a new $repo' again" ;;
    esac
  done

  local n
  mkdir -p "$dir"
  n="$(_p4a_free_subnet)"
  local subnet="10.89.$n.0/24"
  local source_dir="$P4A_PROJECT_VOLUME_PATH/${repo#*/}"
  printf 'repo=%s\nsubnet=%s\nsource=%s\n' "$repo" "$subnet" "$source_dir" > "$conf"
  # From here on, a failure removes everything this command created. The
  # name is expanded now, which is safe: it matches P4A_PROJECT_NAME_PATTERN.
  trap "_p4a_undo_new $project" EXIT
  _p4a_create_additions_file "$project"

  p4a_sandbox_podman volume create "$project_volume" >/dev/null
  p4a_sandbox_podman volume create "$claude_volume" >/dev/null

  p4a_sandbox_podman network create --internal --disable-dns \
    --subnet "$subnet" "$network" >/dev/null

  _p4a_create_proxy "$project"
  _p4a_create_sandbox "$project"
  _p4a_start_project "$project"

  # git signs in with the project's Repo token, if it has one, through the
  # Base image's credential helper. Never prompt for credentials.
  if ! p4a_sandbox_podman exec --env GIT_TERMINAL_PROMPT=0 "$sandbox" \
      git clone "https://github.com/$repo.git" "$source_dir"; then
    p4a_die "couldn't clone $repo from GitHub (see git's message above)" \
      "check that $repo exists; if it's private, store its Repo token with 'p4a secret set repo-token $project'. Then run 'p4a new $repo' again"
  fi

  trap - EXIT
  echo "Created the project $project, with $repo in $source_dir."
  echo "Open a shell in its Sandbox with: p4a shell $project"
}

# _p4a_git_identity ARRAY
# Add to ARRAY the --env options that make commits in a Sandbox carry the
# developer's own name and email, from the Host's git config. Exit if
# either is missing.
_p4a_git_identity() {
  local -n identity_args=$1
  local key value
  for key in name email; do
    value="$(git config --global --get "user.$key")" && [[ -n $value ]] \
      || p4a_die "the Host's git config has no user.$key, which commits in the Sandbox need" \
        "set it with 'git config --global user.$key <your $key>', then try again"
    identity_args+=(--env "GIT_AUTHOR_${key^^}=$value" --env "GIT_COMMITTER_${key^^}=$value")
  done
}

# Print the secrets PROJECT's Sandbox mounts, one "SECRET FILE" line each:
# the Agent token, and the project's own Repo token if it has one. Never
# any other project's.
_p4a_sandbox_secrets() {
  local repo_token
  repo_token="$(p4a_repo_token_secret "$1")"
  echo "$P4A_AGENT_TOKEN_SECRET $P4A_AGENT_TOKEN_FILE"
  if p4a_secret_exists "$repo_token"; then
    echo "$repo_token $P4A_REPO_TOKEN_FILE"
  fi
}

# Print the address of PROJECT's Egress proxy on the project's network.
_p4a_proxy_ip() {
  local subnet
  subnet="$(_p4a_project_setting "$1" subnet)" \
    || p4a_die "the settings for $1 don't say which network address range it uses" \
      "check $(_p4a_projects_dir)/$1.conf has a line 'subnet=10.89.N.0/24'"
  echo "${subnet%.0/24}.2"
}

# Create PROJECT's Egress proxy container: on the project's network at its
# fixed address, and on Podman's default network to reach out. It reads its
# Allowlist from a file p4a writes when it starts (lib/allowlist.sh). Used
# by p4a new, and by p4a start to recreate it.
_p4a_create_proxy() {
  local project=$1 proxy_ip
  proxy_ip="$(_p4a_proxy_ip "$project")"
  p4a_sandbox_podman create --name "$(_p4a_proxy_name "$project")" \
    "${P4A_CONTAINER_HARDENING[@]}" \
    --network podman --network "$(_p4a_network_name "$project"):ip=$proxy_ip" \
    --env "P4A_ALLOWLIST_FILE=$P4A_PROXY_ALLOWLIST_FILE" --env "P4A_PROJECT=$project" \
    "$P4A_PROXY_IMAGE" >/dev/null
}

# Recreate PROJECT's Egress proxy if it was created before proxies read
# their Allowlist from a file, so p4a allow can reach it. The proxy keeps
# nothing but its log. A running proxy is never recreated.
_p4a_refresh_proxy() {
  local project=$1 proxy env
  proxy="$(_p4a_proxy_name "$project")"
  env="$(p4a_sandbox_podman container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$proxy")"
  grep -q '^P4A_ALLOWLIST_FILE=' <<< "$env" && return 0

  if [[ "$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$proxy")" == true ]]; then
    p4a_note "the Egress proxy for $project is from an older podman4ai and can't apply 'p4a allow' changes. To update it, run 'p4a stop $project', then 'p4a start $project'"
    return 0
  fi
  p4a_note "Recreating the Egress proxy for $project so it can apply 'p4a allow' changes. Its earlier log is lost."
  p4a_sandbox_podman rm "$proxy" >/dev/null
  _p4a_create_proxy "$project" \
    || p4a_die "couldn't recreate the Egress proxy for $project (see podman's message above)" \
      "run 'p4a start $project' again"
}

# Create PROJECT's Sandbox container, attached to the project's network
# and volumes, with the current tokens. Used by p4a new, and by p4a start
# to recreate it.
_p4a_create_sandbox() {
  local project=$1 proxy_ip
  proxy_ip="$(_p4a_proxy_ip "$project")"

  local identity=()
  _p4a_git_identity identity
  local var proxy_env=()
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    proxy_env+=(--env "$var=$P4A_PROXY_URL")
  done
  # The tokens, as files only the Sandbox's user can read.
  local list name file secrets=()
  list="$(_p4a_sandbox_secrets "$project")"
  while read -r name file; do
    secrets+=(--secret "$name,type=mount,target=$file,uid=$P4A_SANDBOX_UID,gid=$P4A_SANDBOX_UID,mode=0400")
  done <<< "$list"

  p4a_sandbox_podman create --name "$(_p4a_sandbox_name "$project")" \
    "${P4A_SANDBOX_HARDENING[@]}" \
    --memory="$P4A_SANDBOX_MEMORY" --cpus="$P4A_SANDBOX_CPUS" --pids-limit="$P4A_SANDBOX_PIDS" \
    --network "$(_p4a_network_name "$project")" --dns=none --add-host "$P4A_PROXY_HOST:$proxy_ip" \
    "${proxy_env[@]}" "${identity[@]}" --env "P4A_PROJECT=$project" \
    --volume "$(_p4a_project_volume_name "$project"):$P4A_PROJECT_VOLUME_PATH" \
    --volume "$(_p4a_claude_volume_name "$project"):$P4A_CLAUDE_CONFIG_PATH" \
    "${secrets[@]}" \
    --init "$P4A_BASE_IMAGE" sleep infinity >/dev/null
}

# Recreate PROJECT's Sandbox if it doesn't mount the current tokens.
# Podman copies a container's secrets when it's created, so a token stored
# or replaced since then reaches the Sandbox only this way. Its Project
# volume and Claude config volume are kept; anything else in the container
# is lost. A running Sandbox is never recreated.
_p4a_refresh_sandbox_tokens() {
  local project=$1 sandbox list name file id want=() have
  sandbox="$(_p4a_sandbox_name "$project")"
  list="$(_p4a_sandbox_secrets "$project")"
  while read -r name file; do
    id="$(p4a_sandbox_podman secret inspect --format '{{.ID}}' "$name" < /dev/null)"
    want+=("$name=$id")
  done <<< "$list"
  have="$(p4a_sandbox_podman container inspect \
    --format '{{range .Config.Secrets}}{{.Name}}={{.ID}}{{println}}{{end}}' "$sandbox")"
  [[ "$(printf '%s\n' "${want[@]}" | sort)" == "$(grep -v '^$' <<< "$have" | sort)" ]] && return 0

  if [[ "$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$sandbox")" == true ]]; then
    p4a_note "the Sandbox for $project is running with old tokens. To give it the current ones, run 'p4a stop $project', then 'p4a start $project'"
    return 0
  fi
  p4a_note "Recreating the Sandbox for $project to give it the current tokens. Its source and Claude config are kept; anything else changed inside it is lost."
  p4a_sandbox_podman rm "$sandbox" >/dev/null
  _p4a_create_sandbox "$project" \
    || p4a_die "couldn't recreate the Sandbox for $project (see podman's message above); its volumes are kept" \
      "run 'p4a start $project' again"
}

# Remove every part of PROJECT that p4a new created, after it failed. Only
# called once p4a new has checked that none of them existed before.
_p4a_undo_new() {
  local project=$1
  p4a_note "removing what was created for $project"
  p4a_sandbox_podman rm -f "$(_p4a_sandbox_name "$project")" "$(_p4a_proxy_name "$project")" >/dev/null 2>&1 || true
  p4a_sandbox_podman network rm -f "$(_p4a_network_name "$project")" >/dev/null 2>&1 || true
  p4a_sandbox_podman volume rm -f "$(_p4a_project_volume_name "$project")" "$(_p4a_claude_volume_name "$project")" >/dev/null 2>&1 || true
  rm -f "$(_p4a_projects_dir)/$project.conf" "$(_p4a_additions_file "$project")"
}

# The project names that exist, one per line, sorted.
_p4a_known_projects() {
  local conf
  for conf in "$(_p4a_projects_dir)"/*.conf; do
    [[ ! -e $conf ]] || basename "$conf" .conf
  done | sort
}

# Exit with the known projects unless PROJECT exists.
_p4a_require_project() {
  local project=$1 known
  [[ $project =~ $P4A_PROJECT_NAME_PATTERN && -f "$(_p4a_projects_dir)/$project.conf" ]] && return 0
  known="$(_p4a_known_projects | paste -sd ' ' -)"
  if [[ -z $known ]]; then
    p4a_die "unknown project '$project': there are no projects yet" "create one with 'p4a new <owner/repo>'"
  fi
  p4a_die "unknown project '$project'. Known projects: ${known// /, }" \
    "use one of those names, or create a project with 'p4a new <owner/repo>'"
}

p4a_start() {
  [[ $# -eq 1 ]] || p4a_usage_error "start needs one project name" "p4a --help"
  _p4a_require_project "$1"
  p4a_require_running_sandbox_machine
  p4a_require_agent_token
  _p4a_refresh_proxy "$1"
  _p4a_refresh_sandbox_tokens "$1"
  _p4a_start_project "$1"
}

p4a_stop() {
  [[ $# -eq 1 ]] || p4a_usage_error "stop needs one project name" "p4a --help"
  _p4a_require_project "$1"
  p4a_require_running_sandbox_machine
  _p4a_stop_project "$1"
}

# Start PROJECT's Egress proxy and give it the project's current Allowlist,
# then start its Sandbox and check the Sandbox's network. A Sandbox never
# runs without its proxy, nor with a failed check.
_p4a_start_project() {
  local project=$1
  p4a_sandbox_podman start "$(_p4a_proxy_name "$project")" >/dev/null
  if ! (_p4a_push_allowlist "$project"); then
    _p4a_stop_project "$project" || true
    exit 1
  fi
  p4a_sandbox_podman start "$(_p4a_sandbox_name "$project")" >/dev/null
  _p4a_self_check "$project"
}

# Stop PROJECT's Sandbox and its Egress proxy together.
_p4a_stop_project() {
  local project=$1
  p4a_sandbox_podman stop "$(_p4a_sandbox_name "$project")" "$(_p4a_proxy_name "$project")" >/dev/null
}

# The Sandbox's startup check (ADR 0003): an allowlisted domain is reachable
# through the Egress proxy, and a domain not on the Allowlist is reachable
# neither through the proxy nor directly. On failure, stop the Sandbox and
# its proxy and exit.
P4A_SELF_CHECK_ALLOWED=github.com
P4A_SELF_CHECK_REFUSED=example.com
# The proxy may still be starting, so try the allowlisted domain this many
# times, half a second apart.
P4A_SELF_CHECK_TRIES=10

_p4a_self_check() {
  local project=$1 sandbox proxy error="" i
  sandbox="$(_p4a_sandbox_name "$project")"
  proxy="$(_p4a_proxy_name "$project")"
  for (( i = 1; ; i++ )); do
    error="$(_p4a_probe "$sandbox" "$P4A_SELF_CHECK_ALLOWED" 2>&1)" && break
    if (( i == P4A_SELF_CHECK_TRIES )); then
      _p4a_stop_project "$project" || true
      p4a_die "the Sandbox self-check failed: $P4A_SELF_CHECK_ALLOWED, which is on the Allowlist, isn't reachable through the Egress proxy (${error:-no error message}). $project was stopped." \
        "see the proxy's log with 'p4a podman logs $proxy'; rebuilding the images with 'p4a image build' may help"
    fi
    sleep 0.5
  done
  local route direct
  for route in "through the Egress proxy" "directly"; do
    direct=()
    [[ $route == directly ]] && direct=(--noproxy '*')
    if _p4a_probe "$sandbox" "$P4A_SELF_CHECK_REFUSED" "${direct[@]}" >/dev/null 2>&1; then
      _p4a_stop_project "$project" || true
      p4a_die "the Sandbox self-check failed: it reached $P4A_SELF_CHECK_REFUSED, which isn't on the Allowlist, $route, so its network isn't isolated. $project was stopped." \
        "don't use this Sandbox; report this as a bug"
    fi
  done
}

# _p4a_probe SANDBOX DOMAIN [CURL_OPTION...]
# Succeed if SANDBOX can fetch https://DOMAIN; print curl's error if not.
_p4a_probe() {
  p4a_sandbox_podman exec "$1" curl "https://$2" "${@:3}" --silent --show-error --output /dev/null --max-time 10
}

# p4a shell PROJECT [-- COMMAND...]
# Open a login shell in PROJECT's Sandbox, or run one command there and
# exit with its exit code. Either way, in the project's source folder.
p4a_shell() {
  (( $# )) || p4a_usage_error "shell needs a project name" "p4a --help"
  local project=$1
  shift
  if (( $# )); then
    [[ $1 == -- ]] || p4a_usage_error "shell takes a project name, then optionally -- and a command" "p4a --help"
    shift
  fi
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine

  local sandbox running source_dir
  sandbox="$(_p4a_sandbox_name "$project")"
  running="$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$sandbox")" \
    || p4a_die "couldn't find the Sandbox $sandbox for $project" \
      "check what exists with 'p4a podman ps -a'"
  [[ $running == true ]] \
    || p4a_die "the Sandbox for $project isn't running" "start it with 'p4a start $project'"
  source_dir="$(_p4a_project_setting "$project" source)" \
    || p4a_die "the settings for $project don't say where its source is" \
      "add a line 'source=/workspace/<repo>' to $(_p4a_projects_dir)/$project.conf"

  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  (( $# )) || set -- bash -l
  local status=0
  # p4a-session (in the Base image) hands the Agent token to Claude Code.
  p4a_sandbox_podman exec -i "${tty[@]}" -w "$source_dir" "$sandbox" p4a-session "$@" \
    || status=$?
  return "$status"
}
