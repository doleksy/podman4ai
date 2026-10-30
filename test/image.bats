#!/usr/bin/env bats
# p4a image build: the Egress proxy image, then the Base image built
# through an Egress proxy loaded with the build Allowlist (ADR 0003).

load helpers

BUILD_NETNS=/run/user/1000/netns/netns-build-test

# The Sandbox machine is running, the Egress proxy is listening, and the
# container holding the build's network namespace reports where it is.
build_can_run() {
  machines "podman4ai hyperv running"
  fake_podman "--connection podman4ai inspect --format {{.NetworkSettings.SandboxKey}} podman4ai-build-netns" \
    --stdout "$BUILD_NETNS"
  fake_podman "--connection podman4ai logs podman4ai-build-proxy" \
    --stdout "2026-10-25T23:04:46.000Z listening on port 8888"
  fake_podman "--connection podman4ai run --rm --network none localhost/podman4ai-base claude --version" \
    --stdout "2.1.312 (Claude Code)"
}

# The calls p4a made to Podman inside the Sandbox machine, without the
# leading "--connection podman4ai".
sandbox_calls() {
  podman_calls_starting "--connection podman4ai " | sed 's/^--connection podman4ai //'
}

# Matches the Base image's own build (not the build that labels it).
BASE_BUILD='build .*podman4ai-base .*/images/base$'

# The line number of the first Sandbox-machine call matching REGEX.
call_number() {
  sandbox_calls | grep -n -E "^$1" | head -1 | cut -d: -f1
}

# The build Allowlist as configured in podman4ai, one domain per line.
configured_build_allowlist() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$P4A_REPO/share/build-allowlist" | grep -v '^$'
}

# The Allowlist p4a gave the Egress proxy, one domain per line.
proxy_allowlist() {
  _calls 'c.args.find((a) => a.startsWith("P4A_ALLOWLIST=")) ?? null' \
    | sed 's/^P4A_ALLOWLIST=//' | tr ' ' '\n' | grep -v '^$'
}

@test "image build builds the Egress proxy image, then the Base image, then labels it" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local builds
  builds="$(sandbox_calls | grep '^build ')"
  [ "$(echo "$builds" | wc -l)" -eq 3 ]
  [[ "$(echo "$builds" | sed -n 1p)" == *" -t localhost/podman4ai-proxy "*"/images/proxy" ]]
  [[ "$(echo "$builds" | sed -n 2p)" == *" -t localhost/podman4ai-base "*"/images/base" ]]
  [[ "$(echo "$builds" | sed -n 3p)" == *" -t localhost/podman4ai-base "*"/images/base-labels" ]]
}

@test "the Base image build reaches the network only through an Egress proxy loaded with the build Allowlist" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]

  # The proxy is on the build network at a fixed address, and on the
  # default network to reach out. It has the build Allowlist from
  # podman4ai's own configuration.
  local proxy
  proxy="$(sandbox_calls | grep '^run .* --name podman4ai-build-proxy ')"
  [[ " $proxy " == *" --network podman4ai-build:ip=10.89.200.2 "* ]]
  [[ "$proxy" == *" localhost/podman4ai-proxy" ]]
  [ "$(proxy_allowlist)" == "$(configured_build_allowlist)" ]
  proxy_allowlist | grep -qx deb.debian.org

  # Rootless Podman can't put a build on a named network, so the build
  # joins the network namespace of a container that is on the build
  # network only.
  local holder
  holder="$(sandbox_calls | grep '^run .* --name podman4ai-build-netns ')"
  [[ " $holder " == *" --network podman4ai-build "* ]]
  [ "$(grep -o -- '--network' <<< "$holder" | wc -l)" -eq 1 ]

  local base
  base="$(sandbox_calls | grep "^$BASE_BUILD")"
  [[ " $base " == *" --network ns:$BUILD_NETNS "* ]]
  [ "$(grep -o -- '--network' <<< "$base" | wc -l)" -eq 1 ]
  [[ " $base " == *" --add-host egress-proxy:10.89.200.2 "* ]]
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    [[ " $base " == *" --build-arg $var=http://egress-proxy:8888 "* ]]
  done
  (( $(call_number "run .* --name podman4ai-build-proxy ") < $(call_number "$BASE_BUILD") ))
  (( $(call_number "run .* --name podman4ai-build-netns ") < $(call_number "$BASE_BUILD") ))
}

@test "image build creates the build network with no route out and no DNS" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local create
  create="$(sandbox_calls | grep '^network create ')"
  [[ " $create " == *" --internal "* ]]
  [[ " $create " == *" --disable-dns "* ]]
  [[ " $create " == *" --subnet 10.89.200.0/24 "* ]]
  [[ "$create" == *" podman4ai-build" ]]
  (( $(call_number "network create ") < $(call_number "run ") ))
}

@test "image build replaces any existing build network, so its settings are always p4a's" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  (( $(call_number "network rm -f podman4ai-build$") < $(call_number "network create ") ))
}

@test "the Egress proxy image's own build has no network" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local proxy_build
  proxy_build="$(sandbox_calls | grep '^build .*podman4ai-proxy')"
  [[ " $proxy_build " == *" --network none "* ]]
  [ "$(grep -o -- '--network' <<< "$proxy_build" | wc -l)" -eq 1 ]
}

@test "the Base image is rebuilt from scratch on the latest Debian image" {
  # No cached layers: every download happens again, through the proxy,
  # and picks up the latest OS patches and Claude Code.
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local base
  base="$(sandbox_calls | grep "^$BASE_BUILD")"
  [[ " $base " == *" --no-cache "* ]]
  [[ " $base " == *" --pull=newer "* ]]
}

# What the build's Egress proxy logged.
proxy_logged() {
  fake_podman "--connection podman4ai logs podman4ai-build-proxy" --stdout "$1"
}

PROXY_LOG_WITH_REFUSAL='2026-10-25T23:04:46.000Z listening on port 8888
2026-10-25T23:04:47.258Z allowed GET deb.debian.org:80
2026-10-25T23:04:47.297Z allowed GET deb.debian.org:80
2026-10-25T23:04:50.100Z allowed CONNECT claude.ai:443
2026-10-25T23:04:51.100Z allowed CONNECT downloads.claude.ai:443
2026-10-25T23:04:52.100Z refused CONNECT example.com:443 not on the Allowlist
2026-10-25T23:04:52.200Z refused GET / not a proxy request
2026-10-25T23:04:53.100Z failed CONNECT downloads.claude.ai:443 ECONNRESET'

@test "after the build, p4a lists the domains the Egress proxy allowed and refused, and only domains" {
  build_can_run
  proxy_logged "$PROXY_LOG_WITH_REFUSAL"
  run p4a image build
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed: claude.ai deb.debian.org downloads.claude.ai"* ]]
  [[ "$output" == *"refused: example.com"* ]]
  [[ "$output" == *"p4a podman logs podman4ai-build-proxy"* ]]
}

@test "after the build, the namespace holder is removed and the Egress proxy stopped" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local base
  base="$(call_number "$BASE_BUILD")"
  (( $(call_number "rm -f podman4ai-build-netns$") > base ))
  (( $(call_number "stop .*podman4ai-build-proxy$") > base ))
}

@test "a failed Base image build fails image build, but still cleans up and shows what was refused" {
  build_can_run
  proxy_logged "$PROXY_LOG_WITH_REFUSAL"
  fake_podman "--connection podman4ai build --no-cache" --stderr 'curl: (22) The requested URL returned error: 403' --exit 22
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused: example.com"* ]]
  [[ "$output" == *"the Base image build failed"* ]]
  [[ "$output" == *"share/build-allowlist"* ]]
  podman_calls | grep -q "rm -f podman4ai-build-netns$"
  podman_calls | grep -q "stop .*podman4ai-build-proxy$"
}

@test "the built Base image is labelled with its build date and Claude Code version, by a build with no network" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  local label
  label="$(sandbox_calls | grep '^build .*--label ')"
  [ "$(echo "$label" | wc -l)" -eq 1 ]
  [[ " $label " == *" --label podman4ai.claude-code-version=2.1.312 "* ]]
  [[ " $label " =~ \ --label\ org\.opencontainers\.image\.created=20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z\  ]]
  [[ " $label " == *" -t localhost/podman4ai-base "* ]]
  [[ " $label " == *" --network none "* ]]
  [ "$(grep -o -- '--network' <<< "$label" | wc -l)" -eq 1 ]
  # The version comes from the image just built, run with no network.
  local version
  version="$(sandbox_calls | grep '^run .*localhost/podman4ai-base claude --version$')"
  [[ " $version " == *" --network none "* ]]
  (( $(call_number "$BASE_BUILD") < $(call_number "run .*podman4ai-base claude --version") ))
  (( $(call_number "run .*podman4ai-base claude --version") < $(call_number "build .*--label ") ))
  [[ "$output" == *"Claude Code 2.1.312"* ]]
}

@test "image build fails, without labelling, if Claude Code doesn't run in the Base image just built" {
  build_can_run
  fake_podman "--connection podman4ai run --rm --network none localhost/podman4ai-base claude --version" \
    --stderr "bash: line 1: claude: command not found" --exit 127
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude Code doesn't run in the Base image just built"* ]]
  [[ "$output" == *"claude: command not found"* ]]
  [ -z "$(sandbox_calls | grep '^build .*--label ')" ]
}

@test "image build fails if labelling the Base image fails" {
  build_can_run
  fake_podman "--connection podman4ai build --network none --pull=never" \
    --stderr "Error: creating build container: something went wrong" --exit 125
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't label the Base image"* ]]
  [[ "$output" != *"Built "* ]]
}

@test "image build needs the Sandbox machine to be running" {
  machines "podman4ai hyperv stopped"
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't running"* ]]
  [[ "$output" == *"p4a machine start"* ]]
  [ -z "$(sandbox_calls)" ]
}

@test "image build needs the Sandbox machine to exist" {
  machines
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a machine create"* ]]
  [ -z "$(sandbox_calls)" ]
}

@test "the Base image build waits for the Egress proxy to be listening" {
  build_can_run
  run p4a image build
  [ "$status" -eq 0 ]
  (( $(call_number "logs podman4ai-build-proxy") < $(call_number "$BASE_BUILD") ))
}

@test "image build gives up, without building the Base image, if the Egress proxy never starts listening" {
  build_can_run
  fake_podman "--connection podman4ai logs podman4ai-build-proxy" --stdout "node: something went wrong"
  run p4a image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"the build's Egress proxy didn't start"* ]]
  [[ "$output" == *"node: something went wrong"* ]]
  [ -z "$(sandbox_calls | grep "^$BASE_BUILD")" ]
  podman_calls | grep -q "rm -f podman4ai-build-proxy podman4ai-build-netns$"
}
