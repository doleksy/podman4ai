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

# The hardening every Sandbox gets. Podman's default seccomp and SELinux
# protections stay on because nothing here turns them off.
P4A_SANDBOX_HARDENING=(
  --cap-drop=all
  --security-opt=no-new-privileges
  --user=agent
)

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

# The Podman names of PROJECT's parts.
_p4a_sandbox_name() { echo "podman4ai-$1"; }
_p4a_proxy_name() { echo "podman4ai-$1-proxy"; }
_p4a_network_name() { echo "podman4ai-$1"; }
_p4a_source_volume_name() { echo "podman4ai-$1-source"; }
_p4a_claude_volume_name() { echo "podman4ai-$1-claude"; }

# Where the Project volume and Claude config volume appear in the Sandbox.
P4A_WORKSPACE=/workspace
P4A_CLAUDE_CONFIG=/home/agent/.claude

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
  [[ $project =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || p4a_usage_error "'$repo' doesn't name a GitHub repository p4a can use" "p4a --help"

  local dir conf
  dir="$(_p4a_projects_dir)"
  conf="$dir/$project.conf"
  [[ ! -e $conf ]] \
    || p4a_die "the project $project already exists" "start it with 'p4a start $project'"

  p4a_require_running_sandbox_machine

  local network proxy sandbox source_volume claude_volume
  network="$(_p4a_network_name "$project")"
  proxy="$(_p4a_proxy_name "$project")"
  sandbox="$(_p4a_sandbox_name "$project")"
  source_volume="$(_p4a_source_volume_name "$project")"
  claude_volume="$(_p4a_claude_volume_name "$project")"

  # Parts with these names may be left from an earlier project of the same
  # name, possibly with unpushed work. Never reuse or remove them.
  local kind name
  for kind in volume:"$source_volume" volume:"$claude_volume" network:"$network" \
      container:"$proxy" container:"$sandbox"; do
    name="${kind#*:}"
    if p4a_sandbox_podman "${kind%%:*}" exists "$name"; then
      p4a_die "can't create the project $project: the ${kind%%:*} $name already exists in the Sandbox machine" \
        "if nothing in it is needed, remove it with 'p4a podman ${kind%%:*} rm $name', then run 'p4a new $repo' again"
    fi
  done

  local n
  mkdir -p "$dir"
  n="$(_p4a_free_subnet)"
  local subnet="10.89.$n.0/24" proxy_ip="10.89.$n.2"
  local source_dir="$P4A_WORKSPACE/${repo#*/}"
  printf 'repo=%s\nsubnet=%s\nsource=%s\n' "$repo" "$subnet" "$source_dir" > "$conf"
  # From here on, a failure removes everything this command created.
  trap "_p4a_undo_new $project" EXIT

  p4a_sandbox_podman volume create "$source_volume" >/dev/null
  p4a_sandbox_podman volume create "$claude_volume" >/dev/null

  p4a_sandbox_podman network create --internal --disable-dns \
    --subnet "$subnet" "$network" >/dev/null

  p4a_sandbox_podman create --name "$proxy" \
    --cap-drop=all --security-opt=no-new-privileges \
    --network podman --network "$network:ip=$proxy_ip" \
    --env "P4A_ALLOWLIST=$(p4a_read_allowlist "$P4A_HOME/share/default-allowlist")" \
    "$P4A_PROXY_IMAGE" >/dev/null

  local var proxy_env=()
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    proxy_env+=(--env "$var=$P4A_PROXY_URL")
  done
  p4a_sandbox_podman create --name "$sandbox" \
    "${P4A_SANDBOX_HARDENING[@]}" \
    --memory="$P4A_SANDBOX_MEMORY" --cpus="$P4A_SANDBOX_CPUS" --pids-limit="$P4A_SANDBOX_PIDS" \
    --network "$network" --dns=none --add-host "$P4A_PROXY_HOST:$proxy_ip" \
    "${proxy_env[@]}" \
    --volume "$source_volume:$P4A_WORKSPACE" \
    --volume "$claude_volume:$P4A_CLAUDE_CONFIG" \
    --init "$P4A_BASE_IMAGE" sleep infinity >/dev/null

  _p4a_start_project "$project"

  # Public repositories only for now; never prompt for credentials.
  if ! p4a_sandbox_podman exec --env GIT_TERMINAL_PROMPT=0 "$sandbox" \
      git clone "https://github.com/$repo.git" "$source_dir"; then
    p4a_die "couldn't clone $repo from GitHub (see git's message above)" \
      "check that $repo exists and is public, then run 'p4a new $repo' again"
  fi

  trap - EXIT
  echo "Created the project $project, with $repo in $source_dir."
  echo "Open a shell in its Sandbox with: p4a shell $project"
}

# Remove every part of PROJECT that p4a new created, after it failed. Only
# called once p4a new has checked that none of them existed before.
_p4a_undo_new() {
  local project=$1
  p4a_note "removing what was created for $project"
  p4a_sandbox_podman rm -f "$(_p4a_sandbox_name "$project")" "$(_p4a_proxy_name "$project")" >/dev/null 2>&1 || true
  p4a_sandbox_podman network rm -f "$(_p4a_network_name "$project")" >/dev/null 2>&1 || true
  p4a_sandbox_podman volume rm -f "$(_p4a_source_volume_name "$project")" "$(_p4a_claude_volume_name "$project")" >/dev/null 2>&1 || true
  rm -f "$(_p4a_projects_dir)/$project.conf"
}

# The project name for owner/REPO: the repository's name in lower case.
_p4a_project_name() {
  local name="${1#*/}"
  echo "${name,,}"
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
  [[ -n $project && -f "$(_p4a_projects_dir)/$project.conf" ]] && return 0
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
  _p4a_start_project "$1"
}

p4a_stop() {
  [[ $# -eq 1 ]] || p4a_usage_error "stop needs one project name" "p4a --help"
  _p4a_require_project "$1"
  p4a_require_running_sandbox_machine
  _p4a_stop_project "$1"
}

# Start PROJECT's Egress proxy, then its Sandbox, then check the Sandbox's
# network. A Sandbox never runs without its proxy, nor with a failed check.
_p4a_start_project() {
  local project=$1
  p4a_sandbox_podman start "$(_p4a_proxy_name "$project")" >/dev/null
  p4a_sandbox_podman start "$(_p4a_sandbox_name "$project")" >/dev/null
  _p4a_self_check "$project"
}

# Stop PROJECT's Sandbox and its Egress proxy together.
_p4a_stop_project() {
  local project=$1
  p4a_sandbox_podman stop "$(_p4a_sandbox_name "$project")" "$(_p4a_proxy_name "$project")" >/dev/null
}

# The Sandbox's startup check (ADR 0003): an allowlisted domain is reachable
# through the Egress proxy and a domain not on the Allowlist is not. On
# failure, stop the Sandbox and its proxy and exit.
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
      _p4a_stop_project "$project"
      p4a_die "the Sandbox self-check failed: $P4A_SELF_CHECK_ALLOWED, which is on the Allowlist, isn't reachable through the Egress proxy (${error:-no error message}). $project was stopped." \
        "see the proxy's log with 'p4a podman logs $proxy'; rebuilding the images with 'p4a image build' may help"
    fi
    sleep 0.5
  done
  if _p4a_probe "$sandbox" "$P4A_SELF_CHECK_REFUSED" >/dev/null 2>&1; then
    _p4a_stop_project "$project"
    p4a_die "the Sandbox self-check failed: it reached $P4A_SELF_CHECK_REFUSED, which isn't on the Allowlist, so its network isn't isolated. $project was stopped." \
      "don't use this Sandbox; report this as a bug"
  fi
}

# _p4a_probe SANDBOX DOMAIN
# Succeed if SANDBOX can fetch https://DOMAIN; print curl's error if not.
_p4a_probe() {
  p4a_sandbox_podman exec "$1" curl "https://$2" --silent --show-error --output /dev/null --max-time 10
}

# p4a shell PROJECT [-- COMMAND...]
# Open a login shell in PROJECT's Sandbox, or run one command there and
# exit with its exit code. Either way, in the project's source folder.
p4a_shell() {
  local project="${1:-}"
  (( $# )) && shift
  if (( $# )); then
    [[ $1 == -- ]] || p4a_usage_error "shell takes a project name, then optionally -- and a command" "p4a --help"
    shift
  fi
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine

  local sandbox running
  sandbox="$(_p4a_sandbox_name "$project")"
  running="$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$sandbox")"
  [[ $running == true ]] \
    || p4a_die "the Sandbox for $project isn't running" "start it with 'p4a start $project'"

  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  (( $# )) || set -- bash -l
  local status=0
  p4a_sandbox_podman exec -i "${tty[@]}" -w "$(_p4a_project_setting "$project" source)" "$sandbox" "$@" \
    || status=$?
  return "$status"
}
