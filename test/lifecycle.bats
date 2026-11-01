#!/usr/bin/env bats
# A project's lifecycle: p4a recreate, rm, list and status, and its limits.

load project-helpers

# The calls that remove, create, start or stop containers, with create's
# arguments cut down to the container's name.
container_lifecycle_calls() {
  sandbox_calls | grep -E '^(stop|rm|create|start) ' \
    | sed -E 's/^(create --name [^ ]+) .*/\1/'
}

# hello-world's Sandbox and network exist, and the Sandbox is running
# (true) or not (false).
hello_world_running() {
  fake_podman "--connection podman4ai container exists podman4ai-hello-world" --exit 0
  fake_podman "--connection podman4ai network exists podman4ai-hello-world" --exit 0
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout "$1"
}

@test "recreate replaces a stopped project's Sandbox and Egress proxy, keeps its volumes, and leaves it stopped" {
  hello_world_exists
  hello_world_running false
  run p4a recreate hello-world
  [ "$status" -eq 0 ]
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy
create --name podman4ai-hello-world-proxy
create --name podman4ai-hello-world" ]
  [ -z "$(sandbox_calls | grep -E "^(volume|network) (create|rm)")" ]
  local volumes
  volumes="$(create_args podman4ai-hello-world | flag_values --volume)"
  [ "$volumes" = "podman4ai-hello-world-source:/workspace
podman4ai-hello-world-claude:/home/agent/.claude" ]
  [[ "$output" == *"Recreated hello-world"* ]]
}

@test "recreate stops a running project, replaces its Sandbox and Egress proxy, and starts it again with the self-check" {
  hello_world_exists
  hello_world_running true
  run p4a recreate hello-world
  [ "$status" -eq 0 ]
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy
create --name podman4ai-hello-world-proxy
create --name podman4ai-hello-world
start podman4ai-hello-world-proxy
start podman4ai-hello-world" ]
  [ -n "$(sandbox_calls | grep '^exec podman4ai-hello-world curl https://example.com')" ]
}

@test "recreate --all recreates every project and leaves each running or stopped as it was" {
  hello_world_exists
  p4a new octo/spoon-knife
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  hello_world_running true
  fake_podman "--connection podman4ai container exists podman4ai-spoon-knife" --exit 0
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-spoon-knife" --stdout false
  run p4a recreate --all
  [ "$status" -eq 0 ]
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy
create --name podman4ai-hello-world-proxy
create --name podman4ai-hello-world
start podman4ai-hello-world-proxy
start podman4ai-hello-world
rm -f --ignore podman4ai-spoon-knife podman4ai-spoon-knife-proxy
create --name podman4ai-spoon-knife-proxy
create --name podman4ai-spoon-knife" ]
  [[ "$output" == *"Recreated hello-world"* ]]
  [[ "$output" == *"Recreated spoon-knife"* ]]
}

@test "recreate --all goes on past a project that fails, then fails naming it" {
  hello_world_exists
  p4a new octo/spoon-knife
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  hello_world_running true
  # hello-world's self-check fails after it's recreated.
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://example.com --noproxy" --exit 0
  fake_podman "--connection podman4ai container exists podman4ai-spoon-knife" --exit 0
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-spoon-knife" --stdout true
  run p4a recreate --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check failed"* ]]
  [[ "$output" == *"couldn't recreate hello-world"* ]]
  [[ "$output" == *"Recreated spoon-knife"* ]]
  sandbox_calls | has_line "start podman4ai-spoon-knife"
}

# The calls that removed volumes.
volume_removals() {
  sandbox_calls | grep '^volume rm' || true
}

@test "rm removes the Sandbox, Egress proxy and network, and without confirmation never deletes a volume" {
  hello_world_exists
  hello_world_running true
  local answer
  for answer in "" "y" "yes" "Hello-World" "hello"; do
    : > "$FAKE_PODMAN_DIR/calls.jsonl"
    run p4a rm hello-world <<< "$answer"
    [ "$status" -eq 0 ]
    [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy" ]
    sandbox_calls | has_line "network rm podman4ai-hello-world"
    [ -z "$(volume_removals)" ]
    # It names what deleting them would lose, and says they were kept.
    [[ "$output" == *"podman4ai-hello-world-source"* ]]
    [[ "$output" == *"podman4ai-hello-world-claude"* ]]
    [[ "$output" == *"uncommitted"* ]]
    [[ "$output" == *"Kept"* ]]
    [[ "$output" == *"p4a recreate hello-world"* ]]
    [ -f "$P4A_CONFIG_DIR/projects/hello-world.conf" ]
    [ -f "$P4A_CONFIG_DIR/projects/hello-world.allowlist" ]
  done
}

@test "rm with no terminal input never deletes a volume" {
  hello_world_exists
  run p4a rm hello-world < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$(volume_removals)" ]
  [ -f "$P4A_CONFIG_DIR/projects/hello-world.conf" ]
}

@test "rm deletes the volumes and the project's Host settings only when the project's name is typed to confirm" {
  hello_world_exists
  run p4a rm hello-world <<< "hello-world"
  [ "$status" -eq 0 ]
  [ "$(volume_removals)" = "volume rm podman4ai-hello-world-source podman4ai-hello-world-claude" ]
  [ ! -e "$P4A_CONFIG_DIR/projects/hello-world.conf" ]
  [ ! -e "$P4A_CONFIG_DIR/projects/hello-world.allowlist" ]
  [[ "$output" == *"Removed the project hello-world"* ]]
}

@test "recreate brings back a project whose Sandbox, Egress proxy and network were removed with rm, on its own subnet" {
  hello_world_exists
  # No container or network of hello-world exists; its volumes do.
  run p4a recreate hello-world
  [ "$status" -eq 0 ]
  sandbox_calls | has_line "network create --internal --disable-dns --subnet 10.89.1.0/24 podman4ai-hello-world"
  [ "$(container_lifecycle_calls)" = "rm -f --ignore podman4ai-hello-world podman4ai-hello-world-proxy
create --name podman4ai-hello-world-proxy
create --name podman4ai-hello-world" ]
  [ -z "$(sandbox_calls | grep '^volume ')" ]
}

@test "limits in a project's Host settings override the defaults at recreate, and other projects keep the defaults" {
  hello_world_exists
  p4a new octo/spoon-knife
  printf 'memory=8g\ncpus=6\npids=8192\n' >> "$P4A_CONFIG_DIR/projects/hello-world.conf"
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  run p4a recreate --all
  [ "$status" -eq 0 ]
  local args
  args="$(create_args podman4ai-hello-world)"
  has_line "--memory=8g" <<< "$args"
  has_line "--cpus=6" <<< "$args"
  has_line "--pids-limit=8192" <<< "$args"
  [ "$(grep -cE -- '^--(memory|cpus|pids-limit)=' <<< "$args")" -eq 3 ]
  args="$(create_args podman4ai-spoon-knife)"
  has_line "--memory=4g" <<< "$args"
  has_line "--cpus=4" <<< "$args"
  has_line "--pids-limit=4096" <<< "$args"
}

@test "a limit p4a can't use stops recreate before anything is removed, naming the setting" {
  hello_world_exists
  echo 'memory=lots' >> "$P4A_CONFIG_DIR/projects/hello-world.conf"
  run p4a recreate hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory=lots"* ]]
  [[ "$output" == *"hello-world.conf"* ]]
  [ -z "$(sandbox_calls | grep -E '^(rm|stop|create) ')" ]
}

# sandbox_image PROJECT IMAGE_ID DAYS_OLD
# PROJECT's Sandbox was created from the Base image with IMAGE_ID, labelled
# as built DAYS_OLD days ago (or with no build date if DAYS_OLD is "none").
sandbox_image() {
  local created=""
  [[ $3 == none ]] || created="$(date -u -d "$3 days ago" +%Y-%m-%dT%H:%M:%SZ)"
  fake_podman "--connection podman4ai container exists podman4ai-$1" --exit 0
  fake_podman "--connection podman4ai container inspect --format {{.ImageName}}|{{.Image}} podman4ai-$1" \
    --stdout "localhost/podman4ai-base|$2"
  fake_podman "--connection podman4ai image inspect --format {{index .Labels \"org.opencontainers.image.created\"}} $2" \
    --stdout "$created"
}

# The current Base image's ID.
base_image_id() {
  fake_podman "--connection podman4ai image inspect --format {{.Id}} localhost/podman4ai-base" --stdout "$1"
}

@test "list shows each project, running or stopped, its image and the image's age, and nudges a rebuild past 14 days" {
  hello_world_exists
  p4a new octo/spoon-knife
  hello_world_running true
  sandbox_image hello-world image-a 3
  sandbox_image spoon-knife image-old 20
  base_image_id image-a
  run p4a list
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == PROJECT*STATE*IMAGE*AGE* ]]
  [[ "$output" == *"hello-world"*"running"*"localhost/podman4ai-base"*"3 days"* ]]
  [[ "$output" == *"spoon-knife"*"stopped"*"localhost/podman4ai-base"*"20 days"* ]]
  [[ "$output" == *"over 14 days old"* ]]
  [[ "$output" == *"p4a image build"*"p4a recreate --all"* ]]
  # Only the old one is named in the nudge.
  [[ "$(grep 'over 14 days' <<< "$output")" != *hello-world* ]]
}

@test "list doesn't nudge when every image is recent, and shows a project rm kept as removed" {
  hello_world_exists
  p4a new octo/spoon-knife
  sandbox_image hello-world image-a 2
  base_image_id image-a
  # spoon-knife's Sandbox was removed with p4a rm; its volumes were kept.
  run p4a list
  [ "$status" -eq 0 ]
  [[ "$output" == *"spoon-knife"*"removed"* ]]
  [[ "$output" != *"over 14 days"* ]]
  [[ "$output" == *"p4a recreate spoon-knife"* ]]
}

@test "status shows a project's state, image, build date and age, and nudges a rebuild past 14 days" {
  hello_world_exists
  hello_world_running true
  sandbox_image hello-world image-a 30
  base_image_id image-a
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-world: running"* ]]
  [[ "$output" == *"localhost/podman4ai-base"* ]]
  [[ "$output" == *"$(date -u -d '30 days ago' +%Y-%m-%d)"*"30 days"* ]]
  [[ "$output" == *"over 14 days old"* ]]
  [[ "$output" == *"p4a image build"*"p4a recreate hello-world"* ]]
}

@test "status shows the project's limits, and doesn't nudge for a recent current image" {
  hello_world_exists
  printf 'memory=8g\n' >> "$P4A_CONFIG_DIR/projects/hello-world.conf"
  sandbox_image hello-world image-a 1
  base_image_id image-a
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-world: stopped"* ]]
  [[ "$output" == *"1 day"* ]]
  [[ "$output" == *"8g memory"*"4 CPUs"*"4096 processes"* ]]
  [[ "$output" != *"p4a image build"* ]]
  [[ "$output" != *"newer Base image"* ]]
}

@test "status says to recreate a project whose Sandbox isn't on the current Base image" {
  hello_world_exists
  sandbox_image hello-world image-a 3
  base_image_id image-b
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer Base image"*"p4a recreate hello-world"* ]]
  [[ "$output" != *"p4a image build"* ]]
}

@test "a limit p4a can't use stops start before it removes a Sandbox to give it new tokens" {
  hello_world_exists
  hello_world_mounts "podman4ai-agent-token=old-id
podman4ai-hello-world-repo-token=id-1"
  echo 'cpus=many' >> "$P4A_CONFIG_DIR/projects/hello-world.conf"
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"cpus=many"* ]]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
}

@test "rm again, after an rm that kept the volumes, still offers to delete them" {
  hello_world_exists
  # The Sandbox, Egress proxy and network are gone; podman can't remove a
  # network that doesn't exist.
  fake_podman "--connection podman4ai network rm" --exit 1 --stderr "Error: unable to find network with name or ID podman4ai-hello-world: network not found"
  run p4a rm hello-world <<< "hello-world"
  [ "$status" -eq 0 ]
  [ "$(volume_removals)" = "volume rm podman4ai-hello-world-source podman4ai-hello-world-claude" ]
  [ ! -e "$P4A_CONFIG_DIR/projects/hello-world.conf" ]
}

@test "rm removes nothing if podman can't say whether the Sandbox exists" {
  hello_world_exists
  fake_podman "--connection podman4ai container exists podman4ai-hello-world" --exit 125
  run p4a rm hello-world <<< "hello-world"
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check whether the container podman4ai-hello-world exists"* ]]
  [ -z "$(sandbox_calls | grep -E '^(stop|rm|network rm|volume rm) ')" ]
  [ -f "$P4A_CONFIG_DIR/projects/hello-world.conf" ]
}

@test "recreate stops before removing anything if an image it needs isn't built" {
  hello_world_exists
  hello_world_running true
  fake_podman "--connection podman4ai image exists localhost/podman4ai-base" --exit 1
  run p4a recreate hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"localhost/podman4ai-base"* ]]
  [[ "$output" == *"p4a image build"* ]]
  [ -z "$(sandbox_calls | grep -E '^(stop|rm|create) ')" ]
}

@test "list and status don't claim a newer Base image when there's none" {
  hello_world_exists
  sandbox_image hello-world image-a 2
  fake_podman "--connection podman4ai image inspect --format {{.Id}} localhost/podman4ai-base" --exit 125 \
    --stderr "Error: localhost/podman4ai-base: image not known"
  run p4a list
  [ "$status" -eq 0 ]
  [[ "$output" != *"newer Base image"* ]]
  run p4a status hello-world
  [ "$status" -eq 0 ]
  [[ "$output" != *"newer Base image"* ]]
}
