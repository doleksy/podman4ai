#!/usr/bin/env bats
# A project's Sandbox: p4a new, start, stop and shell.

load project-helpers

@test "new creates a Sandbox with the full hardening flag set and default limits" {
  sandbox_machine_running
  run p4a new octo/hello-world
  [ "$status" -eq 0 ]
  local args
  args="$(create_args podman4ai-hello-world)"
  [ -n "$args" ]
  has_line "--cap-drop=all" <<< "$args"
  has_line "--security-opt=no-new-privileges" <<< "$args"
  has_line "--user=agent" <<< "$args"
  has_line "--memory=4g" <<< "$args"
  has_line "--cpus=4" <<< "$args"
  has_line "--pids-limit=4096" <<< "$args"
  # Default seccomp and SELinux stay on; nothing that widens the boundary.
  [ -z "$(grep -E -- '--privileged|seccomp=unconfined|label=disable|--cap-add|podman\.sock|--userns=host|--pid=host|--ipc=host' <<< "$args")" ]
}


@test "each Sandbox attaches only to its own internal network, and two projects never share one" {
  sandbox_machine_running
  p4a new octo/hello-world
  p4a new octo/spoon-knife

  local one two
  one="$(create_args podman4ai-hello-world | flag_values --network)"
  two="$(create_args podman4ai-spoon-knife | flag_values --network)"
  [ "$(wc -l <<< "$one")" -eq 1 ]
  [ "$(wc -l <<< "$two")" -eq 1 ]
  [ -n "$one" ]
  [ -n "$two" ]
  [ "$one" != "$two" ]

  # Each network has no route out and no DNS, and its own subnet.
  local net subnets=()
  for net in "$one" "$two"; do
    local create
    create="$(sandbox_calls | grep -E "^network create .* $net$")"
    [[ " $create " == *" --internal "* ]]
    [[ " $create " == *" --disable-dns "* ]]
    subnets+=("$(flag_values --subnet <<< "$(tr ' ' '\n' <<< "$create")")")
  done
  [ -n "${subnets[0]}" ]
  [ "${subnets[0]}" != "${subnets[1]}" ]
}

@test "a Sandbox reaches out only through its own Egress proxy, with no outside DNS" {
  sandbox_machine_running
  p4a new octo/hello-world
  local args
  args="$(create_args podman4ai-hello-world)"
  has_line "--dns=none" <<< "$args"
  for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    has_line "$var=http://egress-proxy:8888" <<< "$(flag_values --env <<< "$args")"
  done

  # The name egress-proxy points at the project's proxy, which is on the
  # Sandbox's network at that address and on Podman's default network to
  # reach out.
  local host ip network proxy
  host="$(flag_values --add-host <<< "$args")"
  [[ $host == egress-proxy:* ]]
  ip="${host#egress-proxy:}"
  network="$(flag_values --network <<< "$args")"
  proxy="$(create_args podman4ai-hello-world-proxy)"
  [ -n "$proxy" ]
  has_line "$network:ip=$ip" <<< "$(flag_values --network <<< "$proxy")"
  has_line "podman" <<< "$(flag_values --network <<< "$proxy")"
  [ "$(tail -1 <<< "$proxy")" = localhost/podman4ai-proxy ]
}

@test "new gives the Sandbox its own Project volume and Claude config volume" {
  sandbox_machine_running
  p4a new octo/hello-world
  local volumes
  volumes="$(create_args podman4ai-hello-world | flag_values --volume)"
  has_line "podman4ai-hello-world-source:/workspace" <<< "$volumes"
  has_line "podman4ai-hello-world-claude:/home/agent/.claude" <<< "$volumes"
  [ "$(wc -l <<< "$volumes")" -eq 2 ]
  sandbox_calls | has_line "volume create podman4ai-hello-world-source"
  sandbox_calls | has_line "volume create podman4ai-hello-world-claude"
}

@test "no volume or mount argument ever names a Windows or Host path" {
  sandbox_machine_running
  p4a new octo/hello-world
  p4a new octo/spoon-knife
  # Every volume source is a named Podman volume: no slashes, backslashes
  # or drive letters.
  local mounts
  mounts="$(_calls 'c.args.flatMap((a, i) => {
      const prev = c.args[i - 1];
      if (["-v", "--volume", "--mount"].includes(prev)) return [a];
      const m = a.match(/^(?:-v|--volume|--mount)=(.*)$/);
      return m ? [m[1]] : [];
    }).join("\n") || null')"
  [ -n "$mounts" ]
  [ -z "$(grep -vE '^podman4ai-[a-z0-9._-]+:/' <<< "$mounts")" ]
  [ -z "$(_calls 'c.args.some((a) => a.startsWith("--mount") || a === "--volumes-from" || a.startsWith("--volumes-from=")) ? "x" : null')" ]
}

@test "start starts the Egress proxy, then the Sandbox" {
  hello_world_exists
  run p4a start hello-world
  [ "$status" -eq 0 ]
  local starts
  starts="$(sandbox_calls | grep '^start ')"
  [ "$starts" = "start podman4ai-hello-world-proxy
start podman4ai-hello-world" ]
}

@test "stop stops the Sandbox and its Egress proxy together" {
  hello_world_exists
  run p4a stop hello-world
  [ "$status" -eq 0 ]
  [ "$(sandbox_calls | grep '^stop ')" = "stop podman4ai-hello-world podman4ai-hello-world-proxy" ]
}

@test "start runs the self-check every time: an allowlisted domain is reachable and example.com is not" {
  hello_world_exists
  p4a start hello-world
  p4a start hello-world
  [ "$(sandbox_calls | grep -c '^exec podman4ai-hello-world curl https://github.com')" -eq 2 ]
  [ "$(sandbox_calls | grep '^exec podman4ai-hello-world curl https://example.com' | grep -vc -- '--noproxy')" -eq 2 ]
  # example.com is also tried without the proxy, which must fail too.
  [ "$(sandbox_calls | grep -cF 'exec podman4ai-hello-world curl https://example.com --noproxy *')" -eq 2 ]
  # The checks run after the Sandbox has started.
  [ "$(sandbox_calls | grep -E '^(start |exec podman4ai-hello-world curl )' | head -2 | tail -1)" = "start podman4ai-hello-world" ]
}

@test "a broken Egress proxy makes start fail with a clear message, and leaves nothing running" {
  hello_world_exists
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://github.com"     --stderr "curl: (7) Failed to connect to egress-proxy port 8888" --exit 7
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check failed"* ]]
  [[ "$output" == *"github.com"* ]]
  [[ "$output" == *"p4a podman logs podman4ai-hello-world-proxy"* ]]
  sandbox_calls | has_line "stop podman4ai-hello-world podman4ai-hello-world-proxy"
}

@test "start fails, and leaves nothing running, if the Sandbox can reach a domain not on the Allowlist directly" {
  hello_world_exists
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://example.com --noproxy" --exit 0
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check failed"* ]]
  [[ "$output" == *"example.com"*"directly"* ]]
  sandbox_calls | has_line "stop podman4ai-hello-world podman4ai-hello-world-proxy"
}

@test "a self-check failure is reported even if stopping the Sandbox fails too" {
  hello_world_exists
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://github.com" --exit 7
  fake_podman "--connection podman4ai stop" --exit 125
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check failed"* ]]
}

@test "new stops, creating nothing, if podman can't say whether a part already exists" {
  sandbox_machine_running
  fake_podman "--connection podman4ai volume exists" --exit 125
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check whether the volume podman4ai-hello-world-source exists"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create|rm|volume rm|network rm)')" ]
}

@test "start fails, and leaves nothing running, if the Sandbox can reach a domain not on the Allowlist" {
  hello_world_exists
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://example.com" --exit 0
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check failed"* ]]
  [[ "$output" == *"example.com"* ]]
  sandbox_calls | has_line "stop podman4ai-hello-world podman4ai-hello-world-proxy"
}

@test "new starts the Sandbox and clones the repo into its Project volume over HTTPS" {
  sandbox_machine_running
  run p4a new octo/Hello-World
  [ "$status" -eq 0 ]
  local calls
  calls="$(sandbox_calls)"
  has_line "start podman4ai-hello-world" <<< "$calls"
  has_line "exec --env GIT_TERMINAL_PROMPT=0 podman4ai-hello-world git clone https://github.com/octo/Hello-World.git /workspace/Hello-World" <<< "$calls"
  # The clone comes after the self-check.
  (( $(grep -n 'curl https://example.com' <<< "$calls" | tail -1 | cut -d: -f1) < $(grep -n 'git clone' <<< "$calls" | cut -d: -f1) ))
  [[ "$output" == *"p4a shell hello-world"* ]]
}

@test "new refuses an existing project" {
  hello_world_exists
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"hello-world already exists"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create|rm|volume rm|network rm)')" ]
}

@test "new never reuses or removes a leftover volume, network or container with a project's name" {
  sandbox_machine_running
  fake_podman "--connection podman4ai volume exists podman4ai-hello-world-source" --exit 0
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman4ai-hello-world-source already exists"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create|rm|volume rm|network rm)')" ]
  run p4a start hello-world
  [[ "$output" == *"unknown project"* ]]
}

@test "a failed clone fails new with a clear message, and removes what new created" {
  sandbox_machine_running
  fake_podman "--connection podman4ai exec --env GIT_TERMINAL_PROMPT=0 podman4ai-hello-world git clone"     --stderr "remote: Repository not found." --exit 128
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't clone octo/hello-world"* ]]
  [[ "$output" == *"p4a secret set repo-token hello-world"* ]]
  local calls
  calls="$(sandbox_calls)"
  has_line "rm -f podman4ai-hello-world podman4ai-hello-world-proxy" <<< "$calls"
  has_line "network rm -f podman4ai-hello-world" <<< "$calls"
  has_line "volume rm -f podman4ai-hello-world-source podman4ai-hello-world-claude" <<< "$calls"
  # So new can simply be run again.
  run p4a start hello-world
  [[ "$output" == *"unknown project"* ]]
}

# hello-world's Sandbox is running.
hello_world_running() {
  hello_world_exists
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout true
}

@test "shell -- COMMAND runs one command, signed in with the Agent token, in the Sandbox's source folder and returns its exit code" {
  hello_world_running
  fake_podman "--connection podman4ai exec" --stdout "commit 1234abc" --exit 3
  run p4a shell hello-world -- git -C /workspace/hello-world log -1
  [ "$status" -eq 3 ]
  [[ "$output" == *"commit 1234abc"* ]]
  [ "$(_calls 'c.args[2] === "exec" ? JSON.stringify(c.args) : null')" = '["--connection","podman4ai","exec","-i","-w","/workspace/hello-world","podman4ai-hello-world","p4a-session","git","-C","/workspace/hello-world","log","-1"]' ]
}

@test "shell with no command opens a login shell in the Sandbox's source folder" {
  hello_world_running
  run p4a shell hello-world
  [ "$status" -eq 0 ]
  sandbox_calls | has_line "exec -i -w /workspace/hello-world podman4ai-hello-world p4a-session bash -l"
}

@test "shell into a stopped Sandbox says how to start it" {
  hello_world_exists
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout false
  run p4a shell hello-world -- true
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't running"* ]]
  [[ "$output" == *"p4a start hello-world"* ]]
  [ -z "$(sandbox_calls | grep '^exec ')" ]
}

# The arguments of the call that ran tmux on the terminal, as a JSON array.
claude_session_call() {
  _calls 'c.args.includes("p4a-session") ? JSON.stringify(c.args) : null'
}

# Whether hello-world's Sandbox has a Claude session: yes or no.
claude_session() {
  fake_podman "--connection podman4ai exec podman4ai-hello-world tmux has-session -t =claude" \
    --exit "$([[ $1 == yes ]] && echo 0 || echo 1)"
}

@test "claude starts a tmux session running Claude Code in the source folder, with the extra arguments" {
  hello_world_running
  claude_session no
  run p4a claude hello-world --dangerously-skip-permissions --model "opus 5"
  [ "$status" -eq 0 ]
  [ "$(claude_session_call)" = '["--connection","podman4ai","exec","-i","-w","/workspace/hello-world","podman4ai-hello-world","p4a-session","env","TERM=xterm-256color","tmux","new-session","-A","-s","claude","-c","/workspace/hello-world","claude","--dangerously-skip-permissions","--model","opus 5"]' ]
}

@test "claude reattaches to a running Claude session rather than starting a second one, and says the extra arguments weren't used" {
  hello_world_running
  claude_session yes
  run p4a claude hello-world --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dangerously-skip-permissions"* ]]
  [ "$(claude_session_call)" = '["--connection","podman4ai","exec","-i","-w","/workspace/hello-world","podman4ai-hello-world","p4a-session","env","TERM=xterm-256color","tmux","attach-session","-t","=claude"]' ]
}

@test "claude starts a stopped Sandbox first, with its Egress proxy and self-check" {
  hello_world_exists
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout false
  claude_session no
  run p4a claude hello-world
  [ "$status" -eq 0 ]
  local calls
  calls="$(sandbox_calls)"
  # The proxy, then the Sandbox, then the self-check, then Claude Code.
  [ "$(grep -E '^start |curl https://example.com --noproxy|tmux new-session' <<< "$calls" | cut -d' ' -f1-3)" = "start podman4ai-hello-world-proxy
start podman4ai-hello-world
exec podman4ai-hello-world curl
exec -i -w" ]
  [[ "$output" == *"starting hello-world"* ]]
}

@test "claude fails clearly when it can't check for a Claude session, and starts none" {
  hello_world_running
  fake_podman "--connection podman4ai exec podman4ai-hello-world tmux has-session" --exit 125 \
    --stderr "Error: no container with name or ID podman4ai-hello-world found"
  run p4a claude hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't check for a Claude session in hello-world"* ]]
  [[ "$output" == *"no container with name or ID"* ]]
  [ -z "$(sandbox_calls | grep 'p4a-session')" ]
}

@test "an unknown project name gives a clear error listing the known projects" {
  sandbox_machine_running
  p4a new octo/spoon-knife
  p4a new octo/hello-world
  for command in start stop shell claude; do
    run p4a "$command" hello-wrld
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown project 'hello-wrld'"* ]]
    [[ "$output" == *"Known projects: hello-world, spoon-knife"* ]]
  done
}

@test "each Sandbox is given the Agent token and only its own project's Repo token, as files" {
  sandbox_machine_running
  p4a new octo/hello-world
  p4a new octo/spoon-knife
  [ "$(create_args podman4ai-hello-world | flag_values --secret)" = "podman4ai-agent-token,type=mount,target=agent-token,uid=1000,gid=1000,mode=0400
podman4ai-hello-world-repo-token,type=mount,target=repo-token,uid=1000,gid=1000,mode=0400" ]
  [ "$(create_args podman4ai-spoon-knife | flag_values --secret)" = "podman4ai-agent-token,type=mount,target=agent-token,uid=1000,gid=1000,mode=0400
podman4ai-spoon-knife-repo-token,type=mount,target=repo-token,uid=1000,gid=1000,mode=0400" ]
  # The Egress proxies get no secrets at all.
  [ -z "$(create_args podman4ai-hello-world-proxy | flag_values --secret)" ]
  [ -z "$(create_args podman4ai-spoon-knife-proxy | flag_values --secret)" ]
}

@test "new without an Agent token says how to set it, and creates nothing" {
  sandbox_machine_running
  fake_podman "--connection podman4ai secret exists podman4ai-agent-token" --exit 1
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Agent token"* ]]
  [[ "$output" == *"p4a secret set agent-token"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create|secret create)')" ]
}

@test "start without an Agent token says how to set it, and starts nothing" {
  hello_world_exists
  fake_podman "--connection podman4ai secret exists podman4ai-agent-token" --exit 1
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a secret set agent-token"* ]]
  [ -z "$(sandbox_calls | grep '^start ')" ]
}

@test "a project with no Repo token gets no Repo token mount, and new stores no secret" {
  sandbox_machine_running
  fake_podman "--connection podman4ai secret exists podman4ai-hello-world-repo-token" --exit 1
  run p4a new octo/hello-world
  [ "$status" -eq 0 ]
  [ "$(create_args podman4ai-hello-world | flag_values --secret)" = "podman4ai-agent-token,type=mount,target=agent-token,uid=1000,gid=1000,mode=0400" ]
  [ -z "$(sandbox_calls | grep '^secret create')" ]
}

# What hello-world's Sandbox mounts: lines of SECRET=ID.
hello_world_mounts() {
  fake_podman "--connection podman4ai container inspect --format {{range .Config.Secrets}}{{.Name}}={{.ID}}{{println}}{{end}} podman4ai-hello-world" --stdout "$1"
}

# The calls that remove, create or start hello-world's Sandbox, in order.
sandbox_lifecycle_calls() {
  sandbox_calls | grep -E '^(rm|create --name podman4ai-hello-world |start podman4ai-hello-world$)' | sed 's/^\(create --name podman4ai-hello-world\) .*/\1/'
}

@test "start recreates a stopped Sandbox whose tokens changed, keeping its source and Claude config" {
  hello_world_exists
  # The Agent token was replaced since the Sandbox was created.
  hello_world_mounts "podman4ai-agent-token=old-id
podman4ai-hello-world-repo-token=id-1"
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ "$(sandbox_lifecycle_calls)" = "rm podman4ai-hello-world
create --name podman4ai-hello-world
start podman4ai-hello-world" ]
  [[ "$output" == *"Recreating the Sandbox for hello-world"* ]]
  local args
  args="$(create_args podman4ai-hello-world)"
  has_line "podman4ai-hello-world-source:/workspace" <<< "$(flag_values --volume <<< "$args")"
  has_line "podman4ai-hello-world-claude:/home/agent/.claude" <<< "$(flag_values --volume <<< "$args")"
  [ "$(flag_values --secret <<< "$args" | cut -d, -f1)" = "podman4ai-agent-token
podman4ai-hello-world-repo-token" ]
  # Same hardening, network and identity as p4a new gave it.
  has_line "--cap-drop=all" <<< "$args"
  has_line "--user=agent" <<< "$args"
  has_line "--dns=none" <<< "$args"
  has_line "GIT_AUTHOR_EMAIL=dev@example.com" <<< "$(flag_values --env <<< "$args")"
  [[ "$(flag_values --add-host <<< "$args")" == egress-proxy:10.89.1.2 ]]
}

@test "start leaves a Sandbox whose tokens are current alone" {
  hello_world_exists
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ "$(sandbox_lifecycle_calls)" = "start podman4ai-hello-world" ]
  [[ "$output" != *"Recreating"* ]]
}

@test "start gives a Sandbox the Repo token stored after p4a new" {
  sandbox_machine_running
  fake_podman "--connection podman4ai secret exists podman4ai-hello-world-repo-token" --exit 1
  p4a new octo/hello-world
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  hello_world_mounts "podman4ai-agent-token=id-1"
  fake_podman "--connection podman4ai secret exists podman4ai-hello-world-repo-token" --exit 0
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ "$(create_args podman4ai-hello-world | flag_values --secret | cut -d, -f1)" = "podman4ai-agent-token
podman4ai-hello-world-repo-token" ]
}

@test "start never recreates a running Sandbox, and says how to give it the new tokens" {
  hello_world_exists
  hello_world_mounts "podman4ai-agent-token=old-id
podman4ai-hello-world-repo-token=id-1"
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout true
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
  [[ "$output" == *"p4a stop hello-world"* ]]
}

@test "the Sandbox's git uses the developer's name and email from the Host's git config" {
  sandbox_machine_running
  git config --global user.name "Ada Lovelace"
  git config --global user.email "ada@example.com"
  p4a new octo/hello-world
  local env
  env="$(create_args podman4ai-hello-world | flag_values --env)"
  has_line "GIT_AUTHOR_NAME=Ada Lovelace" <<< "$env"
  has_line "GIT_COMMITTER_NAME=Ada Lovelace" <<< "$env"
  has_line "GIT_AUTHOR_EMAIL=ada@example.com" <<< "$env"
  has_line "GIT_COMMITTER_EMAIL=ada@example.com" <<< "$env"
  # The Sandbox knows its project's name, for messages about its Repo token.
  has_line "P4A_PROJECT=hello-world" <<< "$env"
}

@test "new without a git name and email on the Host says how to set them, and creates nothing" {
  sandbox_machine_running
  git config --global --unset user.email
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"git config --global user.email"* ]]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create|secret create)')" ]
}

@test "start refuses when Podman in the running Sandbox machine doesn't answer, and says how to fix it" {
  hello_world_exists
  podman_not_answering
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't answer"* ]]
  [[ "$output" == *"p4a machine stop"*"p4a machine start"* ]]
  [[ "$output" != *"connectex"* ]]
}
