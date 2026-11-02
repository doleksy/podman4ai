# shellcheck shell=bash
# p4a image: build the images every Sandbox needs.
#
# No build has open internet (ADR 0003). The Egress proxy image's build runs
# no networked steps. The Base image builds on an internal network whose
# only way out is an Egress proxy loaded with the build Allowlist.

P4A_PROXY_IMAGE=localhost/podman4ai-proxy
P4A_BASE_IMAGE=localhost/podman4ai-base

# The build network: internal (no route out) and without DNS, so build
# steps can't resolve outside names either. The proxy sits on it at a fixed
# address and resolves names through Podman's default network.
P4A_BUILD_NETWORK=podman4ai-build
P4A_BUILD_SUBNET=10.89.200.0/24
P4A_BUILD_PROXY_IP=10.89.200.2
P4A_BUILD_PROXY=podman4ai-build-proxy
P4A_BUILD_PROXY_URL=http://egress-proxy:8888
# Rootless Podman can't attach a build to a named network ("cannot use
# networks as rootless"). Instead the build joins the network namespace of
# this idle container, which is on the build network only.
P4A_BUILD_NETNS_HOLDER=podman4ai-build-netns

p4a_image() {
  local command="${1:-}"
  case $command in
    "" | -h | --help | help) p4a_image_usage ;;
    build) shift; p4a_image_build "$@" ;;
    *) p4a_usage_error "unknown command 'image $command'" "p4a image --help" ;;
  esac
}

p4a_image_usage() {
  cat <<EOF
Usage: p4a image <command>

Commands:
  build   build the Egress proxy image ($P4A_PROXY_IMAGE), then the
          Base image ($P4A_BASE_IMAGE) through an Egress proxy
  build <project>
          build the project's Project image ($(_p4a_project_image '<project>'))
          from <project>.Containerfile in its Host settings
          ($(_p4a_projects_dir)), through an Egress proxy loaded
          with the project's Allowlist. It must build on the Base image.
EOF
}

# Print the build Allowlist's domains, separated by spaces.
_p4a_build_allowlist() {
  p4a_read_allowlist "$P4A_HOME/share/build-allowlist"
}

p4a_image_build() {
  (( $# <= 1 )) || p4a_usage_error "image build takes at most one project name" "p4a image --help"
  (( $# == 0 )) || { _p4a_build_project_image "$1"; return; }
  p4a_require_running_sandbox_machine

  p4a_sandbox_podman build --network none \
    -t "$P4A_PROXY_IMAGE" "$(p4a_native_path "$P4A_HOME/images/proxy")"

  # No cache and the newest Debian image: every download happens again,
  # through the proxy, and brings the latest OS patches and Claude Code.
  local built=true created
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _p4a_build_through_proxy "$(_p4a_build_allowlist)" --no-cache --pull=newer \
    -t "$P4A_BASE_IMAGE" "$(p4a_native_path "$P4A_HOME/images/base")" \
    || built=false

  $built || p4a_die "the Base image build failed" \
    "see the build output above; if it needed a refused domain, and that domain should be allowed, add it to $P4A_HOME/share/build-allowlist"

  local version
  version="$(_p4a_label_base_image "$created")" || exit 1
  echo "Built $P4A_PROXY_IMAGE and $P4A_BASE_IMAGE (Claude Code $version, built $created)."
}

# _p4a_build_through_proxy ALLOWLIST BUILD_OPTION... CONTEXT
# Run podman build with these options on the build network, whose only way
# out is an Egress proxy loaded with ALLOWLIST (domains separated by
# spaces). Then report what the proxy allowed and refused, and return the
# build's exit status.
_p4a_build_through_proxy() {
  local allowlist=$1 context="${!#}"
  local options=("${@:2:$#-2}")

  # Start from a fresh build network, so its settings are always these.
  # This also removes the previous build's proxy and namespace holder.
  p4a_sandbox_podman rm -f "$P4A_BUILD_PROXY" "$P4A_BUILD_NETNS_HOLDER" >/dev/null
  p4a_sandbox_podman network rm -f "$P4A_BUILD_NETWORK" >/dev/null
  p4a_sandbox_podman network create --internal --disable-dns \
    --subnet "$P4A_BUILD_SUBNET" "$P4A_BUILD_NETWORK" >/dev/null

  p4a_sandbox_podman run -d --name "$P4A_BUILD_PROXY" \
    --network podman --network "$P4A_BUILD_NETWORK:ip=$P4A_BUILD_PROXY_IP" \
    -e "P4A_ALLOWLIST=$allowlist" \
    "$P4A_PROXY_IMAGE" >/dev/null
  _p4a_wait_for_build_proxy
  p4a_sandbox_podman run -d --name "$P4A_BUILD_NETNS_HOLDER" \
    --network "$P4A_BUILD_NETWORK" \
    "$P4A_PROXY_IMAGE" sleep infinity >/dev/null
  local netns
  netns="$(p4a_sandbox_podman inspect --format '{{.NetworkSettings.SandboxKey}}' "$P4A_BUILD_NETNS_HOLDER")"

  local var proxy_args=()
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    proxy_args+=(--build-arg "$var=$P4A_BUILD_PROXY_URL")
  done
  local status=0
  p4a_sandbox_podman build "${options[@]}" \
    --network "ns:$netns" \
    --add-host "egress-proxy:$P4A_BUILD_PROXY_IP" \
    "${proxy_args[@]}" \
    "$context" || status=$?

  # Keep the stopped proxy until the next build, so its log can be read.
  p4a_sandbox_podman rm -f "$P4A_BUILD_NETNS_HOLDER" >/dev/null
  p4a_sandbox_podman stop -t 2 "$P4A_BUILD_PROXY" >/dev/null
  _p4a_report_build_domains
  return "$status"
}

# The Base image's labels: when it was built (the OCI standard label) and
# which Claude Code it has. Read them with
#   p4a podman image inspect --format '{{json .Labels}}' localhost/podman4ai-base
P4A_CREATED_LABEL=org.opencontainers.image.created
P4A_CLAUDE_VERSION_LABEL=podman4ai.claude-code-version

# _p4a_label_base_image CREATED
# Add the labels to the Base image just built, with no network, and print
# its Claude Code version. The version is known only once the image
# exists, so the labels are a small build of their own on top of it.
_p4a_label_base_image() {
  local created=$1 out version
  out="$(p4a_sandbox_podman run --rm --network none "$P4A_BASE_IMAGE" claude --version 2>&1)" || true
  # Claude Code prints "2.1.312 (Claude Code)".
  version="${out%% *}"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*$ ]] \
    || p4a_die "Claude Code doesn't run in the Base image just built: 'claude --version' said: ${out:-(nothing)}" \
      "see the build output above for the Claude Code install step, then run 'p4a image build' again"
  p4a_sandbox_podman build --network none --pull=never \
    --build-arg "BASE_IMAGE=$P4A_BASE_IMAGE" \
    --label "$P4A_CREATED_LABEL=$created" \
    --label "$P4A_CLAUDE_VERSION_LABEL=$version" \
    -t "$P4A_BASE_IMAGE" "$(p4a_native_path "$P4A_HOME/images/base-labels")" >/dev/null \
    || p4a_die "couldn't label the Base image (see podman's message above)" \
      "run 'p4a image build' again"
  echo "$version"
}

# Wait until the build proxy is listening, so the first build step doesn't
# find nothing there. Give up after about 10 seconds.
_p4a_wait_for_build_proxy() {
  local log i
  for (( i = 0; i < 20; i++ )); do
    log="$(p4a_sandbox_podman logs "$P4A_BUILD_PROXY" 2>&1 || true)"
    [[ $log == *"listening on port"* ]] && return 0
    sleep 0.5
  done
  p4a_sandbox_podman rm -f "$P4A_BUILD_PROXY" "$P4A_BUILD_NETNS_HOLDER" >/dev/null
  p4a_die "the build's Egress proxy didn't start. Its log: ${log:-(empty)}" \
    "rebuild the proxy image with 'p4a image build'; if this keeps happening, report it as a bug"
}

# Summarise the build proxy's log: which domains it allowed and refused.
_p4a_report_build_domains() {
  local log allowed refused
  log="$(p4a_sandbox_podman logs "$P4A_BUILD_PROXY" 2>&1)"
  allowed="$(_p4a_logged_domains allowed <<< "$log")"
  refused="$(_p4a_logged_domains refused <<< "$log")"
  echo "Egress proxy for this build:"
  echo "  allowed: ${allowed:-(none)}"
  echo "  refused: ${refused:-(none)}"
  echo "  full log: p4a podman logs $P4A_BUILD_PROXY"
}

# Read Egress proxy log lines on stdin and print, space separated and
# sorted, the domains of the lines with this VERDICT (allowed or refused).
# Requests too malformed to name a domain are left out.
_p4a_logged_domains() {
  local _time verdict _method target _rest domains=()
  while read -r _time verdict _method target _rest; do
    [[ $verdict == "$1" && $target =~ ^([a-z0-9.-]+):[0-9]+$ ]] \
      && domains+=("${BASH_REMATCH[1]}")
  done
  (( ${#domains[@]} )) || return 0
  printf '%s\n' "${domains[@]}" | sort -u | paste -sd ' ' -
}

# Project images (#14). A project that needs extra toolchains gets an image
# built on the Base image from a Containerfile in its Host settings, which
# no Agent can edit (ADR 0002).

# The name of PROJECT's Project image.
_p4a_project_image() {
  echo "localhost/podman4ai-project-$1"
}

# Where PROJECT's Containerfile is: in its Host settings, never its repo.
_p4a_containerfile() {
  echo "$(_p4a_projects_dir)/$1.Containerfile"
}

# Build PROJECT's Project image from the Containerfile in its Host settings,
# through an Egress proxy loaded with the project's effective Allowlist.
_p4a_build_project_image() {
  local project=$1 containerfile image
  _p4a_require_project "$project"
  containerfile="$(_p4a_containerfile "$project")"
  image="$(_p4a_project_image "$project")"
  [[ -f $containerfile ]] \
    || p4a_die "$project has no Project image: there's no $containerfile" \
      "write a Containerfile there that starts with 'FROM $P4A_BASE_IMAGE', then run 'p4a image build $project' again"
  _p4a_require_base_image_containerfile "$project" "$containerfile"
  p4a_require_running_sandbox_machine
  local needed
  for needed in "$P4A_PROXY_IMAGE" "$P4A_BASE_IMAGE"; do
    _p4a_part_exists image "$needed" \
      || p4a_die "the image $needed isn't built, and a Project image build needs it" \
        "build it with 'p4a image build', then run 'p4a image build $project' again"
  done

  # The build sees only the Containerfile: an empty folder with a copy of it.
  local context
  context="$(mktemp -d)"
  # shellcheck disable=SC2064 # expanded now: the folder is this one
  trap "rm -rf '$context'" EXIT
  cp "$containerfile" "$context/Containerfile"

  local built=true created allowlist
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  allowlist="$(_p4a_effective_allowlist "$project" | paste -sd ' ' -)"
  _p4a_build_through_proxy "$allowlist" --no-cache --pull=never \
    --label "$P4A_CREATED_LABEL=$created" \
    -t "$image" "$(p4a_native_path "$context")" \
    || built=false

  $built || p4a_die "the Project image build for $project failed" \
    "see the build output above; if it needed a refused domain that $project should reach, allow it with 'p4a allow $project <domain>', then run 'p4a image build $project' again"
  echo "Built $image (built $created)."
  echo "To move $project's Sandbox onto it, run: p4a recreate $project"
}

# _p4a_require_base_image_containerfile PROJECT CONTAINERFILE
# Exit, saying why, unless every build stage in CONTAINERFILE starts from
# the Base image or from an earlier stage, so the Project image is built on
# the Base image. A FROM naming a variable is refused too, since its image
# can't be known here. (The build also never pulls, so a FROM this misses
# fails rather than reaching a registry.)
_p4a_require_base_image_containerfile() {
  local project=$1 file=$2 line joined="" words=() image stages=" " froms=0
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    # A line ending in a backslash continues on the next.
    if [[ $line =~ \\[[:space:]]*$ ]]; then
      joined+="${line%\\*} "
      continue
    fi
    read -ra words <<< "$joined$line"
    joined=""
    [[ ${words[0]:-} =~ ^[Ff][Rr][Oo][Mm]$ ]] || continue
    froms=$(( froms + 1 ))
    words=("${words[@]:1}")
    while [[ ${words[0]:-} == --* ]]; do words=("${words[@]:1}"); done
    image="${words[0]:-}"
    if [[ $image != "$P4A_BASE_IMAGE" && $image != "$P4A_BASE_IMAGE:latest" \
        && $stages != *" ${image,,} "* ]]; then
      p4a_die "the Containerfile for $project starts a build stage from '${image:-(nothing)}', but a Project image must build on the Base image" \
        "start every stage with 'FROM $P4A_BASE_IMAGE' (or an earlier stage's name) in $file"
    fi
    [[ ${words[1]:-} =~ ^[Aa][Ss]$ && -n ${words[2]:-} ]] && stages+="${words[2],,} "
  done < "$file"
  (( froms )) || p4a_die "the Containerfile for $project has no FROM line, but a Project image must build on the Base image" \
    "start it with 'FROM $P4A_BASE_IMAGE' in $file"
}

# Print the image PROJECT's Sandbox is created from: its Project image if
# it has a Containerfile, otherwise the Base image. Exit, saying how to
# build it, if its Project image isn't built.
_p4a_sandbox_image() {
  local project=$1 image
  [[ -f "$(_p4a_containerfile "$project")" ]] || { echo "$P4A_BASE_IMAGE"; return 0; }
  image="$(_p4a_project_image "$project")"
  _p4a_part_exists image "$image" \
    || p4a_die "$project has a Containerfile, but its Project image $image isn't built" \
      "build it with 'p4a image build $project', then try again"
  echo "$image"
}
