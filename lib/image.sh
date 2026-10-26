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
    build) p4a_image_build ;;
    *) p4a_usage_error "unknown command 'image $command'" "p4a image --help" ;;
  esac
}

p4a_image_usage() {
  cat <<EOF
Usage: p4a image <command>

Commands:
  build   build the Egress proxy image ($P4A_PROXY_IMAGE), then the
          Base image ($P4A_BASE_IMAGE) through an Egress proxy
EOF
}

# Print the build Allowlist's domains, separated by spaces.
_p4a_build_allowlist() {
  local line domains=()
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n $line ]] && domains+=("$line")
  done < "$P4A_HOME/share/build-allowlist"
  echo "${domains[*]}"
}

p4a_image_build() {
  p4a_require_running_sandbox_machine

  p4a_sandbox_podman build --network none \
    -t "$P4A_PROXY_IMAGE" "$(p4a_native_path "$P4A_HOME/images/proxy")"

  # Start from a fresh build network, so its settings are always these.
  # This also removes the previous build's proxy and namespace holder.
  p4a_sandbox_podman rm -f "$P4A_BUILD_PROXY" "$P4A_BUILD_NETNS_HOLDER" >/dev/null
  p4a_sandbox_podman network rm -f "$P4A_BUILD_NETWORK" >/dev/null
  p4a_sandbox_podman network create --internal --disable-dns \
    --subnet "$P4A_BUILD_SUBNET" "$P4A_BUILD_NETWORK" >/dev/null

  p4a_sandbox_podman run -d --name "$P4A_BUILD_PROXY" \
    --network podman --network "$P4A_BUILD_NETWORK:ip=$P4A_BUILD_PROXY_IP" \
    -e "P4A_ALLOWLIST=$(_p4a_build_allowlist)" \
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
  # No cache and the newest Debian image: every download happens again,
  # through the proxy, and brings the latest OS patches and Claude Code.
  local built=true
  p4a_sandbox_podman build --no-cache --pull=newer \
    --network "ns:$netns" \
    --add-host "egress-proxy:$P4A_BUILD_PROXY_IP" \
    "${proxy_args[@]}" \
    -t "$P4A_BASE_IMAGE" "$(p4a_native_path "$P4A_HOME/images/base")" \
    || built=false

  # Keep the stopped proxy until the next build, so its log can be read.
  p4a_sandbox_podman rm -f "$P4A_BUILD_NETNS_HOLDER" >/dev/null
  p4a_sandbox_podman stop -t 2 "$P4A_BUILD_PROXY" >/dev/null
  _p4a_report_build_domains

  $built || p4a_die "the Base image build failed" \
    "see the build output above; if it needed a refused domain, and that domain should be allowed, add it to $P4A_HOME/share/build-allowlist"
  echo "Built $P4A_PROXY_IMAGE and $P4A_BASE_IMAGE."
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
