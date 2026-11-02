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
  _p4a_require_images
  [[ $1 == --all ]] || { _p4a_recreate_project "$1"; return; }

  local projects
  projects="$(_p4a_known_projects)"
  if [[ -z $projects ]]; then
    echo "There are no projects yet. Create one with: p4a new <owner/repo>"
    return 0
  fi
  # Each project in a p4a of its own, so one that fails (its self-check,
  # say) still leaves the rest recreated.
  local project failed=()
  while read -r project; do
    "$P4A_HOME/bin/p4a" recreate "$project" < /dev/null || failed+=("$project")
  done <<< "$projects"
  (( ${#failed[@]} == 0 )) \
    || p4a_die "couldn't recreate ${failed[*]} (see the messages above); every other project was recreated" \
      "fix what the messages say, then run 'p4a recreate <project>' for each"
}

# Replace PROJECT's Sandbox and Egress proxy with new ones from the current
# images and settings, keeping its volumes and network. A project that was
# running is started again, with the self-check; a stopped one stays
# stopped.
_p4a_recreate_project() {
  local project=$1 state
  _p4a_check_sandbox_can_be_created "$project"
  state="$(_p4a_sandbox_state "$project")"
  _p4a_remove_containers "$project"
  _p4a_part_exists network "$(_p4a_network_name "$project")" || _p4a_create_network "$project"
  _p4a_create_proxy "$project" \
    || p4a_die "couldn't create the Egress proxy for $project (see podman's message above); its volumes are kept" \
      "run 'p4a recreate $project' again"
  _p4a_create_sandbox "$project" \
    || p4a_die "couldn't create the Sandbox for $project (see podman's message above); its volumes are kept" \
      "run 'p4a recreate $project' again"
  [[ $state != running ]] || _p4a_start_project "$project"
  echo "Recreated $project from the current images; its source and Claude config are kept."
}

# Exit, saying how to build them, unless the Egress proxy image and the
# Base image both exist, so nothing is removed that can't be recreated.
_p4a_require_images() {
  local image
  for image in "$P4A_PROXY_IMAGE" "$P4A_BASE_IMAGE"; do
    _p4a_part_exists image "$image" \
      || p4a_die "the image $image isn't built, so a Sandbox can't be recreated" \
        "build the images with 'p4a image build', then try again"
  done
}

# Remove PROJECT's Sandbox and Egress proxy, stopping them first if they're
# running. Either may already be gone.
_p4a_remove_containers() {
  p4a_sandbox_podman rm -f --ignore "$(_p4a_sandbox_name "$1")" "$(_p4a_proxy_name "$1")" >/dev/null
}

# _p4a_part_exists KIND NAME
# Succeed if the KIND (container, network, volume or image) NAME exists in
# the Sandbox machine, fail if not. Exit if podman can't tell.
_p4a_part_exists() {
  local status=0
  p4a_sandbox_podman "$1" exists "$2" || status=$?
  case $status in
    0) return 0 ;;
    1) return 1 ;;
    *) p4a_die "couldn't check whether the $1 $2 exists (podman exited with $status)" \
         "check the Sandbox machine with 'p4a machine status'" ;;
  esac
}

# Print the state of PROJECT's Sandbox: running, stopped, or removed if it
# doesn't exist (after p4a rm, which may keep the volumes).
_p4a_sandbox_state() {
  local sandbox running
  sandbox="$(_p4a_sandbox_name "$1")"
  _p4a_part_exists container "$sandbox" || { echo removed; return 0; }
  running="$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$sandbox")"
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

  # Exits, removing nothing, if podman can't say what exists.
  local network
  network="$(_p4a_network_name "$project")"
  _p4a_part_exists container "$(_p4a_sandbox_name "$project")" || true
  _p4a_remove_containers "$project"
  if _p4a_part_exists network "$network"; then
    p4a_sandbox_podman network rm "$network" >/dev/null
  fi
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
  local project_image
  project_image="$(_p4a_project_image "$project")"
  p4a_sandbox_podman image rm --ignore "$project_image" >/dev/null \
    || p4a_note "couldn't delete the Project image $project_image; delete it later with 'p4a podman image rm $project_image'"
  rm -f "$(_p4a_projects_dir)/$project.conf" "$(_p4a_additions_file "$project")" "$(_p4a_containerfile "$project")"
  echo "Removed the project $project, with its volumes and Host settings."
}

# A Sandbox whose image is older than this many days gets a nudge to
# rebuild the images (for OS patches and a newer Claude Code) and recreate.
P4A_IMAGE_MAX_AGE_DAYS=14

# _p4a_read_project_status PROJECT BASE_ID
# Set P4A_STATE (running, stopped or removed), P4A_IMAGE (the Sandbox's
# image name), P4A_IMAGE_BUILT (its build date, or empty if unknown),
# P4A_IMAGE_DAYS (its age in whole days, or empty), P4A_PROJECT_IMAGE and
# P4A_IMAGE_CURRENT (true unless a newer image for it is built: its Project
# image if it has a Containerfile, otherwise the Base image, BASE_ID).
# P4A_PROJECT_IMAGE is one of:
#   none      no Containerfile: the Sandbox uses the Base image
#   unbuilt   a Containerfile, but no Project image built from it
#   old-base  a Project image built on an older Base image than BASE_ID
#   current   a Project image built on the current Base image (or one
#             built before p4a recorded which)
_p4a_read_project_status() {
  local project=$1 base_id=$2 want_id=$2 info image_id
  P4A_STATE="$(_p4a_sandbox_state "$project")"
  P4A_IMAGE="" P4A_IMAGE_BUILT="" P4A_IMAGE_DAYS="" P4A_IMAGE_CURRENT=true P4A_PROJECT_IMAGE=none
  if _p4a_has_containerfile "$project"; then
    local project_image built_on
    project_image="$(_p4a_project_image "$project")"
    P4A_PROJECT_IMAGE=current
    want_id="$(p4a_sandbox_podman image inspect --format '{{.Id}}' "$project_image" 2>/dev/null)" \
      || { want_id=""; P4A_PROJECT_IMAGE=unbuilt; }
    if [[ $P4A_PROJECT_IMAGE == current && -n $base_id ]]; then
      built_on="$(p4a_sandbox_podman image inspect \
        --format "{{index .Labels \"$P4A_BASE_ID_LABEL\"}}" "$project_image" 2>/dev/null)" || built_on=""
      [[ -z $built_on || $built_on == "$base_id" ]] || P4A_PROJECT_IMAGE="old-base"
    fi
  fi
  [[ $P4A_STATE != removed ]] || return 0
  info="$(p4a_sandbox_podman container inspect --format '{{.ImageName}}|{{.Image}}' "$(_p4a_sandbox_name "$project")")"
  P4A_IMAGE="${info%%|*}" image_id="${info#*|}"
  # With the image it should use not built, there's nothing newer to move to.
  [[ -z $want_id || $image_id == "$want_id" ]] || P4A_IMAGE_CURRENT=false
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
  local base_id project old=() old_project_images=false stale=() unbuilt=() old_base=() removed=()
  base_id="$(_p4a_base_image_id)"
  printf '%-24s %-8s %-28s %s\n' PROJECT STATE IMAGE AGE
  while read -r project; do
    _p4a_read_project_status "$project" "$base_id"
    [[ $P4A_PROJECT_IMAGE != unbuilt ]] || unbuilt+=("$project")
    if [[ $P4A_STATE == removed ]]; then
      printf '%-24s %-8s %-28s %s\n' "$project" removed - -
      removed+=("$project")
      continue
    fi
    printf '%-24s %-8s %-28s %s\n' "$project" "$P4A_STATE" "$P4A_IMAGE" "$(_p4a_image_age)"
    # An unbuilt Project image has its own nudge, which covers the rest.
    [[ $P4A_PROJECT_IMAGE != unbuilt ]] || continue
    if _p4a_image_is_old; then
      old+=("$project")
      [[ $P4A_PROJECT_IMAGE == none ]] || old_project_images=true
    elif [[ $P4A_PROJECT_IMAGE == old-base ]]; then
      old_base+=("$project")
    elif [[ $P4A_IMAGE_CURRENT == false ]]; then
      stale+=("$project")
    fi
  done <<< "$projects"

  if (( ${#old[@]} )); then
    echo
    echo "The images of ${old[*]} are over $P4A_IMAGE_MAX_AGE_DAYS days old (or of unknown age)."
    echo "For the latest OS patches and Claude Code, run 'p4a image build', then 'p4a recreate --all'."
    if $old_project_images; then
      echo "Rebuild each Project image among them with 'p4a image build <project>' before recreating."
    fi
  fi
  if (( ${#stale[@]} )); then
    echo
    echo "A newer image is built for ${stale[*]}. To use it, run 'p4a recreate <project>' for each."
  fi
  local p
  for p in "${old_base[@]}"; do
    echo
    echo "$p's Project image was built on an older Base image. Rebuild it with 'p4a image build $p', then run 'p4a recreate $p'."
  done
  for p in "${unbuilt[@]}"; do
    echo
    echo "$p has a Containerfile, but its Project image isn't built. Build it with 'p4a image build $p', then run 'p4a recreate $p'."
  done
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
  if [[ $P4A_PROJECT_IMAGE != none ]]; then
    echo "  It has a Project image, from $(_p4a_containerfile "$project")"
  fi
  echo "  limits: $memory memory, $cpus CPUs, $pids processes (set in $(_p4a_projects_dir)/$project.conf; changes apply at 'p4a recreate $project')"
  local rebuild="'p4a image build'" newer=Base
  if [[ $P4A_PROJECT_IMAGE != none ]]; then
    rebuild+=", then 'p4a image build $project'"
    newer=Project
  fi
  if [[ $P4A_PROJECT_IMAGE == unbuilt ]]; then
    echo
    echo "Its Project image isn't built. Build it with 'p4a image build $project', then run 'p4a recreate $project'."
  elif _p4a_image_is_old; then
    echo
    echo "Its image is over $P4A_IMAGE_MAX_AGE_DAYS days old (or of unknown age). For the latest OS patches and"
    echo "Claude Code, run $rebuild, then 'p4a recreate $project'."
  elif [[ $P4A_PROJECT_IMAGE == old-base ]]; then
    echo
    echo "Its Project image was built on an older Base image. Rebuild it with 'p4a image build $project', then run 'p4a recreate $project'."
  elif [[ $P4A_IMAGE_CURRENT == false ]]; then
    echo
    echo "A newer $newer image is built. To use it, run 'p4a recreate $project'."
  fi
}
