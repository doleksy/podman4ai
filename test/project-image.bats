#!/usr/bin/env bats
# Project images: p4a image build <project>, and Sandboxes that use them.

load project-helpers

# A Project image for hello-world that adds Go.
GO_CONTAINERFILE='FROM localhost/podman4ai-base
USER root
RUN curl -fsSL https://go.dev/dl/go1.25.0.linux-amd64.tar.gz | tar -C /usr/local -xz
USER agent'

# hello-world's Containerfile in its Host settings.
hello_world_containerfile() {
  printf '%s\n' "$1" > "$P4A_CONFIG_DIR/projects/hello-world.Containerfile"
}

# The images the build needs exist, its Egress proxy starts listening, and
# its network namespace holder reports where the namespace is.
project_build_can_run() {
  fake_podman "--connection podman4ai image exists" --exit 0
  fake_podman "--connection podman4ai inspect --format {{.NetworkSettings.SandboxKey}} podman4ai-build-netns" \
    --stdout /run/user/1000/netns/netns-build-test
  fake_podman "--connection podman4ai logs podman4ai-build-proxy" \
    --stdout "2026-10-25T23:04:46.000Z listening on port 8888"
}

# The Containerfile each build was given, one build per call to this.
built_containerfiles() {
  _calls 'c.args.includes("build") ? c.containerfile : null'
}

# The Project image build's arguments, one per line.
project_build_args() {
  _calls 'c.args.includes("build") && c.args.includes("localhost/podman4ai-project-hello-world") ? c.args.slice(2).join("\n") : null'
}

@test "image build PROJECT builds the Containerfile from the project's Host settings" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a image build hello-world
  [ "$status" -eq 0 ]
  [ "$(built_containerfiles)" = "$GO_CONTAINERFILE" ]
  project_build_args | has_line localhost/podman4ai-project-hello-world
  [[ "$output" == *"Built localhost/podman4ai-project-hello-world"* ]]
}

@test "image build PROJECT ignores a Containerfile anywhere but the project's Host settings" {
  hello_world_exists
  project_build_can_run
  # In the folder p4a runs from, and in a folder there named after the project.
  cd "$BATS_TEST_TMPDIR"
  printf 'FROM localhost/podman4ai-base\n' > Containerfile
  mkdir -p hello-world && printf 'FROM localhost/podman4ai-base\n' > hello-world/Containerfile
  run p4a image build hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Project image"* ]]
  [[ "$output" == *"$P4A_CONFIG_DIR/projects/hello-world.Containerfile"* ]]
  [ -z "$(sandbox_calls | grep '^build ')" ]
}

@test "image build PROJECT refuses a Containerfile that doesn't start from the Base image, saying why" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile 'FROM docker.io/library/golang:1.25
RUN go version'
  run p4a image build hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker.io/library/golang:1.25"* ]]
  [[ "$output" == *"must build on the Base image"* ]]
  [[ "$output" == *"FROM localhost/podman4ai-base"* ]]
  [[ "$output" == *"hello-world.Containerfile"* ]]
  [ -z "$(sandbox_calls | grep -E '^(build|run) ')" ]
}

@test "image build PROJECT refuses any build stage that starts from another image, or from a variable" {
  hello_world_exists
  project_build_can_run
  local containerfile
  for containerfile in \
      $'FROM golang:1.25 AS go\nFROM localhost/podman4ai-base\nCOPY --from=go /usr/local/go /usr/local/go' \
      $'FROM localhost/podman4ai-base\nFROM \\n  ubuntu' \
      $'ARG BASE=localhost/podman4ai-base\nFROM $BASE' \
      $'# no FROM at all\nRUN true'; do
    hello_world_containerfile "$containerfile"
    run p4a image build hello-world
    [ "$status" -eq 1 ]
    [[ "$output" == *"must build on the Base image"* ]]
  done
  [ -z "$(sandbox_calls | grep -E '^(build|run) ')" ]
}

@test "image build PROJECT accepts stages built on the Base image or on an earlier stage" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile '# syntax note: a comment
from localhost/podman4ai-base:latest as tools
RUN echo tools
FROM --platform=linux/amd64 TOOLS
RUN echo final'
  run p4a image build hello-world
  [ "$status" -eq 0 ]
}

@test "the Project image build never pulls an image, so nothing reaches a registry around the Egress proxy" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a image build hello-world
  [ "$status" -eq 0 ]
  project_build_args | has_line --pull=never
  [ -z "$(project_build_args | grep -- '--pull=' | grep -v -- '--pull=never')" ]
}

# The Allowlist p4a gave the build's Egress proxy, one domain per line.
build_proxy_allowlist() {
  _calls 'c.args.includes("podman4ai-build-proxy") && c.args.includes("run") ? (c.args.find((a) => a.startsWith("P4A_ALLOWLIST=")) ?? null) : null' \
    | sed 's/^P4A_ALLOWLIST=//' | tr ' ' '\n' | grep -v '^$'
}

@test "the Project image build reaches the network only through an Egress proxy loaded with the project's effective Allowlist" {
  hello_world_exists
  p4a new octo/spoon-knife
  p4a allow hello-world go.dev
  p4a allow hello-world dl.google.com
  p4a allow spoon-knife example.org
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a image build hello-world
  [ "$status" -eq 0 ]

  # The default Allowlist plus hello-world's own additions, and nothing
  # from the build Allowlist or another project.
  local default
  default="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$P4A_REPO/share/default-allowlist" | grep -v '^$')"
  [ "$(build_proxy_allowlist)" = "$default
go.dev
dl.google.com" ]

  # The build joins the network namespace of a container on the build
  # network only, and its downloads go to the proxy.
  local args
  args="$(project_build_args)"
  [ "$(flag_values --network <<< "$args")" = "ns:/run/user/1000/netns/netns-build-test" ]
  [ "$(flag_values --add-host <<< "$args")" = "egress-proxy:10.89.200.2" ]
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    flag_values --build-arg <<< "$args" | has_line "$var=http://egress-proxy:8888"
  done
  [[ "$output" == *"allowed: "* ]]
}

@test "a failed Project image build says how to allow a domain the proxy refused" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  fake_podman "--connection podman4ai logs podman4ai-build-proxy" --stdout '2026-10-25T23:04:46.000Z listening on port 8888
2026-10-25T23:04:52.100Z refused CONNECT go.dev:443 not on the Allowlist'
  fake_podman "--connection podman4ai build --no-cache --pull=never" --exit 22 --stderr 'curl: (56) CONNECT tunnel failed, response 403'
  run p4a image build hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused: go.dev"* ]]
  [[ "$output" == *"Project image build for hello-world failed"* ]]
  [[ "$output" == *"p4a allow hello-world <domain>"* ]]
  [[ "$output" != *"Built "* ]]
}

@test "the Project image is labelled with its build date" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a image build hello-world
  [ "$status" -eq 0 ]
  [[ "$(flag_values --label < <(project_build_args))" =~ ^org\.opencontainers\.image\.created=20[0-9]{2}-[01][0-9]-[0-3][0-9]T ]]
}

@test "image build PROJECT needs the Base image built first" {
  hello_world_exists
  project_build_can_run
  hello_world_containerfile "$GO_CONTAINERFILE"
  fake_podman "--connection podman4ai image exists localhost/podman4ai-base" --exit 1
  run p4a image build hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"localhost/podman4ai-base"*"isn't built"* ]]
  [[ "$output" == *"p4a image build"* ]]
  [ -z "$(sandbox_calls | grep -E '^(build|run) ')" ]
}

@test "image build PROJECT needs a known project" {
  run p4a image build nonesuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown project 'nonesuch'"* ]]
}

# The image hello-world's Sandbox was created from.
sandbox_image_used() {
  create_args podman4ai-hello-world | flag_values --init
}

@test "recreate puts a project with a Project image onto it, and other projects stay on the Base image" {
  hello_world_exists
  p4a new octo/spoon-knife
  hello_world_containerfile "$GO_CONTAINERFILE"
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  run p4a recreate --all
  [ "$status" -eq 0 ]
  [ "$(sandbox_image_used)" = localhost/podman4ai-project-hello-world ]
  [ "$(create_args podman4ai-spoon-knife | flag_values --init)" = localhost/podman4ai-base ]
}

@test "recreate stops before removing anything if the project's Project image isn't built" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  fake_podman "--connection podman4ai image exists localhost/podman4ai-project-hello-world" --exit 1
  run p4a recreate hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project image"*"isn't built"* ]]
  [[ "$output" == *"p4a image build hello-world"* ]]
  [ -z "$(sandbox_calls | grep -E '^(stop|rm|create) ')" ]
}

@test "start, recreating a Sandbox for new tokens, puts it on the Project image, or stops first if that isn't built" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  hello_world_mounts "podman4ai-agent-token=old-id
podman4ai-hello-world-repo-token=id-1"
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout false
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ "$(sandbox_image_used)" = localhost/podman4ai-project-hello-world ]

  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  fake_podman "--connection podman4ai image exists localhost/podman4ai-project-hello-world" --exit 1
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a image build hello-world"* ]]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
}

@test "new refuses a Containerfile left from an earlier project of the same name" {
  sandbox_machine_running
  mkdir -p "$P4A_CONFIG_DIR/projects"
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"hello-world.Containerfile is left from an earlier project"* ]]
  [ -z "$(sandbox_calls | grep -E 'create ')" ]
}

@test "rm, once confirmed, deletes the project's Containerfile and its Project image too" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a rm hello-world <<< "hello-world"
  [ "$status" -eq 0 ]
  [ ! -e "$P4A_CONFIG_DIR/projects/hello-world.Containerfile" ]
  sandbox_calls | has_line "image rm --ignore localhost/podman4ai-project-hello-world"
}

@test "rm without confirmation keeps the Containerfile and the Project image" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  run p4a rm hello-world <<< "no"
  [ "$status" -eq 0 ]
  [ -f "$P4A_CONFIG_DIR/projects/hello-world.Containerfile" ]
  [ -z "$(sandbox_calls | grep '^image rm')" ]
}

PROJECT_IMAGE=localhost/podman4ai-project-hello-world

# The current ID of hello-world's Project image.
project_image_id() {
  fake_podman "--connection podman4ai image inspect --format {{.Id}} $PROJECT_IMAGE" --stdout "$1"
}

@test "list and status show which projects use a Project image, and its age" {
  hello_world_exists
  p4a new octo/spoon-knife
  hello_world_containerfile "$GO_CONTAINERFILE"
  sandbox_image hello-world image-p 5 "$PROJECT_IMAGE"
  project_image_id image-p
  sandbox_image spoon-knife image-b 2
  base_image_id image-b
  run p4a list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-world"*"$PROJECT_IMAGE"*"5 days"* ]]
  [[ "$output" == *"spoon-knife"*"localhost/podman4ai-base"*"2 days"* ]]
  # Its own Project image is current, so no nudge to move to the Base image.
  [[ "$output" != *"newer"* ]]

  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"image:  $PROJECT_IMAGE"*"5 days old"* ]]
  [[ "$output" == *"Project image, from $P4A_CONFIG_DIR/projects/hello-world.Containerfile"* ]]
  [[ "$output" != *"newer"* ]]

  run p4a status spoon-knife
  [[ "$output" != *"Project image"* ]]
}

@test "status says to recreate a project whose Sandbox isn't on its current Project image" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  # Still on the Base image, from before its Project image was built.
  sandbox_image hello-world image-b 2
  base_image_id image-b
  project_image_id image-p
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer Project image"*"p4a recreate hello-world"* ]]
  run p4a list
  [[ "$output" == *"newer image"*"hello-world"* ]]
}

@test "status says to build a project's Project image when its Containerfile has none yet" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  sandbox_image hello-world image-b 2
  base_image_id image-b
  fake_podman "--connection podman4ai image inspect --format {{.Id}} $PROJECT_IMAGE" --exit 125 \
    --stderr "Error: $PROJECT_IMAGE: image not known"
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"isn't built"*"p4a image build hello-world"*"p4a recreate hello-world"* ]]
}

@test "an old Project image's nudge says to rebuild the Project image too" {
  hello_world_exists
  hello_world_containerfile "$GO_CONTAINERFILE"
  sandbox_image hello-world image-p 20 "$PROJECT_IMAGE"
  project_image_id image-p
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"over 14 days old"*"p4a image build"*"p4a image build hello-world"*"p4a recreate hello-world"* ]]
  run p4a list
  [[ "$output" == *"over 14 days old"*"p4a image build <project>"* ]]
}
