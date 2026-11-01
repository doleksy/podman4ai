# shellcheck shell=bash
# A project's lifecycle: p4a recreate, rm, list and status.
#
# A Sandbox and its Egress proxy are disposable: everything worth keeping
# is in the project's volumes and Host settings. Recreating them is how a
# project gets a rebuilt image or new limits.

# p4a recreate PROJECT | --all
p4a_recreate() {
  [[ $# -eq 1 ]] || p4a_usage_error "recreate needs one project name, or --all" "p4a --help"
  [[ $1 == --all ]] || _p4a_require_project "$1"
  p4a_require_running_sandbox_machine
  p4a_require_agent_token
  [[ $1 == --all ]] || { _p4a_recreate_project "$1"; return; }

  # Each project in a p4a of its own, so one that fails (its self-check,
  # say) still leaves the rest recreated.
  local project failed=()
  while read -r project; do
    [[ -n $project ]] || continue
    "$P4A_HOME/bin/p4a" recreate "$project" < /dev/null || failed+=("$project")
  done < <(_p4a_known_projects)
  (( ${#failed[@]} == 0 )) \
    || p4a_die "couldn't recreate ${failed[*]} (see the messages above); every other project was recreated" \
      "fix what the messages say, then run 'p4a recreate <project>' for each"
}

# Replace PROJECT's Sandbox and Egress proxy with new ones from the current
# images and settings, keeping its volumes and network. A project that was
# running is started again, with the self-check; a stopped one stays
# stopped.
_p4a_recreate_project() {
  local project=$1 sandbox proxy running
  # Check the limits settings before removing anything.
  # shellcheck disable=SC2034 # only checked here; _p4a_create_sandbox uses them
  local limits=()
  _p4a_sandbox_limits "$project" limits
  sandbox="$(_p4a_sandbox_name "$project")"
  proxy="$(_p4a_proxy_name "$project")"
  running="$(_p4a_sandbox_state "$project")"
  [[ $running != running ]] || _p4a_stop_project "$project"
  p4a_sandbox_podman rm -f --ignore "$sandbox" "$proxy" >/dev/null
  local status=0
  p4a_sandbox_podman network exists "$(_p4a_network_name "$project")" || status=$?
  case $status in
    0) ;;
    1) _p4a_create_network "$project" ;;
    *) p4a_die "couldn't check whether the network of $project exists (podman exited with $status)" \
         "check the Sandbox machine with 'p4a machine status', then run 'p4a recreate $project' again" ;;
  esac
  _p4a_create_proxy "$project"
  _p4a_create_sandbox "$project"
  [[ $running != running ]] || _p4a_start_project "$project"
  echo "Recreated $project from the current images; its source and Claude config are kept."
}

# Print the state of PROJECT's Sandbox: running, stopped, or missing if it
# doesn't exist (as after p4a rm, which keeps the volumes).
_p4a_sandbox_state() {
  local status=0 running
  p4a_sandbox_podman container exists "$(_p4a_sandbox_name "$1")" || status=$?
  case $status in
    0) ;;
    1) echo missing; return 0 ;;
    *) p4a_die "couldn't check whether the Sandbox for $1 exists (podman exited with $status)" \
         "check the Sandbox machine with 'p4a machine status'" ;;
  esac
  running="$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$(_p4a_sandbox_name "$1")")"
  [[ $running == true ]] && echo running || echo stopped
}

# p4a rm PROJECT
# Remove PROJECT's Sandbox, Egress proxy and network. Then delete its
# volumes and Host settings too, but only if the developer types the
# project's name to confirm. Otherwise they're kept, and p4a recreate
# brings the project back with them.
p4a_rm() {
  [[ $# -eq 1 ]] || p4a_usage_error "rm needs one project name" "p4a --help"
  local project=$1
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine

  [[ "$(_p4a_sandbox_state "$project")" != running ]] || _p4a_stop_project "$project"
  p4a_sandbox_podman rm -f --ignore "$(_p4a_sandbox_name "$project")" "$(_p4a_proxy_name "$project")" >/dev/null
  p4a_sandbox_podman network rm -f "$(_p4a_network_name "$project")" >/dev/null
  echo "Removed the Sandbox, Egress proxy and network of $project."

  local project_volume claude_volume answer=""
  project_volume="$(_p4a_project_volume_name "$project")"
  claude_volume="$(_p4a_claude_volume_name "$project")"
  cat >&2 <<EOF
Its volumes are still there. Deleting them can't be undone, and loses:
  $project_volume: the project's source, including any uncommitted,
    unpushed or stashed work
  $claude_volume: its Claude Code settings, hooks and memory
EOF
  read -rp "To delete them, and the project's Host settings, type '$project': " answer || true
  if [[ $answer != "$project" ]]; then
    echo "Kept $project's volumes and Host settings. Bring its Sandbox back with: p4a recreate $project"
    echo "To delete them later, run 'p4a rm $project' again."
    return 0
  fi
  p4a_sandbox_podman volume rm "$project_volume" "$claude_volume" >/dev/null \
    || p4a_die "couldn't delete the volumes of $project (see podman's message above); its Host settings are kept" \
      "run 'p4a rm $project' again"
  rm -f "$(_p4a_projects_dir)/$project.conf" "$(_p4a_additions_file "$project")"
  echo "Removed the project $project, with its volumes and Host settings."
}

# A Sandbox whose image is older than this many days gets a nudge to
# rebuild the images (for OS patches and a newer Claude Code) and recreate.
P4A_IMAGE_MAX_AGE_DAYS=14

# _p4a_read_project_status PROJECT BASE_ID
# Set P4A_STATE (running, stopped or removed), P4A_IMAGE (the Sandbox's
# image name), P4A_IMAGE_BUILT (its build date, or empty if unknown),
# P4A_IMAGE_DAYS (its age in whole days, or empty) and P4A_IMAGE_CURRENT
# (true if it's the current Base image, BASE_ID).
_p4a_read_project_status() {
  local project=$1 base_id=$2 info image_id
  P4A_STATE="$(_p4a_sandbox_state "$project")"
  P4A_IMAGE="" P4A_IMAGE_BUILT="" P4A_IMAGE_DAYS="" P4A_IMAGE_CURRENT=true
  if [[ $P4A_STATE == missing ]]; then
    P4A_STATE=removed
    return 0
  fi
  info="$(p4a_sandbox_podman container inspect --format '{{.ImageName}}|{{.Image}}' "$(_p4a_sandbox_name "$project")")"
  P4A_IMAGE="${info%%|*}" image_id="${info#*|}"
  [[ $image_id == "$base_id" ]] || P4A_IMAGE_CURRENT=false
  local created
  created="$(p4a_sandbox_podman image inspect \
    --format "{{index .Labels \"$P4A_CREATED_LABEL\"}}" "$image_id" 2>/dev/null)" || created=""
  [[ $created =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 0
  local built_at now
  built_at="$(date -u -d "$created" +%s 2>/dev/null)" || return 0
  now="$(date -u +%s)"
  P4A_IMAGE_BUILT="${created%%T*}"
  P4A_IMAGE_DAYS=$(( (now - built_at) / 86400 ))
}

# Print the age of the image _p4a_read_project_status read: "3 days".
_p4a_image_age() {
  if [[ -z $P4A_IMAGE_DAYS ]]; then
    echo "unknown"
  elif (( P4A_IMAGE_DAYS == 1 )); then
    echo "1 day"
  else
    echo "$P4A_IMAGE_DAYS days"
  fi
}

# Succeed if the image _p4a_read_project_status read is due for a rebuild:
# older than the threshold, or of unknown age.
_p4a_image_is_old() {
  [[ -z $P4A_IMAGE_DAYS ]] || (( P4A_IMAGE_DAYS > P4A_IMAGE_MAX_AGE_DAYS ))
}

# Print the current Base image's ID, or nothing if there's none.
_p4a_base_image_id() {
  p4a_sandbox_podman image inspect --format '{{.Id}}' "$P4A_BASE_IMAGE" 2>/dev/null || true
}

# p4a list
# One line per project: its state, its Sandbox's image and that image's
# age. Then what to do about any old image or removed Sandbox.
p4a_list() {
  [[ $# -eq 0 ]] || p4a_usage_error "list takes no arguments" "p4a --help"
  p4a_require_running_sandbox_machine
  local projects
  projects="$(_p4a_known_projects)"
  if [[ -z $projects ]]; then
    echo "There are no projects yet. Create one with: p4a new <owner/repo>"
    return 0
  fi
  local base_id project old=() stale=() removed=()
  base_id="$(_p4a_base_image_id)"
  printf '%-24s %-8s %-28s %s\n' PROJECT STATE IMAGE AGE
  while read -r project; do
    _p4a_read_project_status "$project" "$base_id"
    if [[ $P4A_STATE == removed ]]; then
      printf '%-24s %-8s %-28s %s\n' "$project" removed - -
      removed+=("$project")
      continue
    fi
    printf '%-24s %-8s %-28s %s\n' "$project" "$P4A_STATE" "$P4A_IMAGE" "$(_p4a_image_age)"
    if _p4a_image_is_old; then
      old+=("$project")
    elif [[ $P4A_IMAGE_CURRENT == false ]]; then
      stale+=("$project")
    fi
  done <<< "$projects"

  if (( ${#old[@]} )); then
    echo
    echo "The images of ${old[*]} are over $P4A_IMAGE_MAX_AGE_DAYS days old (or of unknown age)."
    echo "For the latest OS patches and Claude Code, run 'p4a image build', then 'p4a recreate --all'."
  fi
  if (( ${#stale[@]} )); then
    echo
    echo "A newer Base image than ${stale[*]} use is built. To use it, run 'p4a recreate <project>' for each."
  fi
  local p
  for p in "${removed[@]}"; do
    echo
    echo "$p's Sandbox was removed and its volumes kept. Bring it back with: p4a recreate $p"
  done
}

# p4a status [PROJECT]
# PROJECT's state, its Sandbox's image and that image's build date and age,
# and its limits, with what to do about an old image. With no project, the
# same as p4a list.
p4a_status() {
  (( $# )) || { p4a_list "$@"; return; }
  [[ $# -eq 1 ]] || p4a_usage_error "status takes at most one project name" "p4a --help"
  local project=$1
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine
  _p4a_read_project_status "$project" "$(_p4a_base_image_id)"

  local limits=() memory cpus pids
  _p4a_sandbox_limits "$project" limits
  memory="${limits[0]#*=}" cpus="${limits[1]#*=}" pids="${limits[2]#*=}"

  echo "$project: $P4A_STATE"
  if [[ $P4A_STATE == removed ]]; then
    echo "  Its Sandbox was removed and its volumes kept. Bring it back with: p4a recreate $project"
    return 0
  fi
  echo "  image:  $P4A_IMAGE, built ${P4A_IMAGE_BUILT:-on an unknown date} ($(_p4a_image_age) old)"
  echo "  limits: $memory memory, $cpus CPUs, $pids processes (set in $(_p4a_projects_dir)/$project.conf; changes apply at 'p4a recreate $project')"
  if _p4a_image_is_old; then
    echo
    echo "Its image is over $P4A_IMAGE_MAX_AGE_DAYS days old (or of unknown age). For the latest OS patches and"
    echo "Claude Code, run 'p4a image build', then 'p4a recreate $project'."
  elif [[ $P4A_IMAGE_CURRENT == false ]]; then
    echo
    echo "A newer Base image is built. To use it, run 'p4a recreate $project'."
  fi
}
