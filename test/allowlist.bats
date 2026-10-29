#!/usr/bin/env bats
# A project's Allowlist: p4a allow, disallow and blocked, and how p4a
# gives each project's Egress proxy its effective Allowlist.

load project-helpers

# Where a project's Egress proxy reads its Allowlist from.
PROXY_ALLOWLIST_FILE=/home/node/allowlist

# PROJECT's Egress proxy is running.
proxy_running() {
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-$1-proxy" --stdout true
}

# The domains p4a last wrote to PROXY's Allowlist file, one per line.
pushed_allowlist() {
  _calls "c.args[2] === \"exec\" && c.args[3] === \"$1\" && c.args.includes(\"$PROXY_ALLOWLIST_FILE\")
    ? c.args.slice(c.args.indexOf(\"$PROXY_ALLOWLIST_FILE\") + 1).join(\" \") : null" | tail -1 | tr ' ' '\n'
}

# The default Allowlist's domains, one per line.
default_allowlist() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$P4A_REPO/share/default-allowlist" | grep -v '^$'
}

# PROJECT's Allowlist additions, as saved on the Host, one per line.
saved_additions() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$P4A_CONFIG_DIR/projects/$1.allowlist" | grep -v '^$' || true
}

@test "allow saves the domain in the project's Host settings and gives its running proxy the default Allowlist plus it" {
  hello_world_exists
  proxy_running hello-world
  run p4a allow hello-world Example.ORG
  [ "$status" -eq 0 ]
  [ "$(saved_additions hello-world)" = "example.org" ]
  [ "$(pushed_allowlist podman4ai-hello-world-proxy)" = "$(default_allowlist; echo example.org)" ]
  has_line "api.anthropic.com" <<< "$(pushed_allowlist podman4ai-hello-world-proxy)"
  [[ "$output" == *"example.org"*"within a few seconds"* ]]
}

@test "allow adds to the project's earlier additions" {
  hello_world_exists
  proxy_running hello-world
  p4a allow hello-world example.org
  p4a allow hello-world '*.cdn.example.net'
  [ "$(saved_additions hello-world)" = "example.org
*.cdn.example.net" ]
  [ "$(pushed_allowlist podman4ai-hello-world-proxy | tail -2)" = "example.org
*.cdn.example.net" ]
}

@test "one project's additions never reach another project's proxy" {
  hello_world_exists
  p4a new octo/spoon-knife
  proxy_running hello-world
  proxy_running spoon-knife
  p4a allow hello-world example.org
  p4a allow spoon-knife example.net
  [ "$(pushed_allowlist podman4ai-spoon-knife-proxy)" = "$(default_allowlist; echo example.net)" ]
  p4a allow hello-world example.info
  [ "$(pushed_allowlist podman4ai-hello-world-proxy)" = "$(default_allowlist; echo example.org; echo example.info)" ]
  [ "$(saved_additions spoon-knife)" = "example.net" ]
}

@test "allow for a stopped project only saves the domain, and says it applies when the project starts" {
  hello_world_exists
  run p4a allow hello-world example.org
  [ "$status" -eq 0 ]
  [ "$(saved_additions hello-world)" = "example.org" ]
  [ -z "$(pushed_allowlist podman4ai-hello-world-proxy)" ]
  [[ "$output" == *"p4a start hello-world"* ]]
}

@test "allow saves the domain even when the Sandbox machine is stopped" {
  hello_world_exists
  machines "podman4ai hyperv stopped"
  run p4a allow hello-world example.org
  [ "$status" -eq 0 ]
  [ "$(saved_additions hello-world)" = "example.org" ]
  [ -z "$(sandbox_calls | grep '^exec ')" ]
}

@test "allow of a domain that's already allowed changes nothing and says so" {
  hello_world_exists
  run p4a allow hello-world github.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com is already on the default Allowlist"* ]]
  [ -z "$(saved_additions hello-world)" ]
  p4a allow hello-world example.org
  run p4a allow hello-world example.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"already allowed"* ]]
  [ "$(saved_additions hello-world)" = "example.org" ]
}

@test "allow refuses anything that isn't a domain name, saving nothing" {
  hello_world_exists
  for bad in https://example.org example.org/path example.org:443 localhost '*' '*.org' 'a b.org' '-x.org' 'ex%61mple.org' '.example.org'; do
    run p4a allow hello-world "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"isn't a domain name"* ]]
    [[ "$output" == *"example.org"* ]]
  done
  [ -z "$(saved_additions hello-world)" ]
}

@test "allow refuses the domain the Sandbox's startup self-check must find refused" {
  hello_world_exists
  run p4a allow hello-world example.com
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-check"* ]]
  [ -z "$(saved_additions hello-world)" ]
}

@test "allow and disallow with the wrong arguments fail with a usage error" {
  for args in "allow" "allow hello-world" "allow a b c" "disallow" "disallow hello-world" "blocked" "blocked a b"; do
    # shellcheck disable=SC2086
    run p4a $args
    [ "$status" -eq 2 ]
    [[ "$output" == *"p4a --help"* ]]
  done
}

@test "allow for an unknown project fails, listing the known ones" {
  hello_world_exists
  run p4a allow hello-wrld example.org
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown project 'hello-wrld'"* ]]
  [ ! -e "$P4A_CONFIG_DIR/projects/hello-wrld.allowlist" ]
}

@test "Allowlist settings are only ever read from and written to the Host config folder" {
  hello_world_exists
  proxy_running hello-world
  # Files with a project's settings' names anywhere else, such as in a repo
  # p4a is run from or the home folder, are ignored.
  local repo="$BATS_TEST_TMPDIR/some-repo"
  mkdir -p "$repo/projects"
  for dir in "$repo" "$repo/projects" "$HOME"; do
    echo "evil.example" > "$dir/hello-world.allowlist"
  done
  local before
  before="$(cd "$BATS_TEST_TMPDIR" && find . -path ./podman -prune -o -path ./config -prune -o -type f -print | sort | xargs md5sum)"

  (cd "$repo" && p4a allow hello-world example.org)
  (cd "$repo" && p4a disallow hello-world example.org)
  (cd "$repo" && p4a allow hello-world example.net)

  [ -z "$(pushed_allowlist podman4ai-hello-world-proxy | grep -x evil.example)" ]
  has_line "example.net" <<< "$(pushed_allowlist podman4ai-hello-world-proxy)"
  [ "$(saved_additions hello-world)" = "example.net" ]
  # Nothing outside the Host config folder changed.
  [ "$(cd "$BATS_TEST_TMPDIR" && find . -path ./podman -prune -o -path ./config -prune -o -type f -print | sort | xargs md5sum)" = "$before" ]
  # And nothing was written into the Sandbox: only its proxy was told.
  [ -z "$(sandbox_calls | grep -E '^(exec|cp) podman4ai-hello-world ')" ]
}

@test "disallow removes the domain from the project's additions and gives its running proxy the rest" {
  hello_world_exists
  proxy_running hello-world
  p4a allow hello-world example.org
  p4a allow hello-world example.net
  run p4a disallow hello-world EXAMPLE.org
  [ "$status" -eq 0 ]
  [ "$(saved_additions hello-world)" = "example.net" ]
  [ "$(pushed_allowlist podman4ai-hello-world-proxy)" = "$(default_allowlist; echo example.net)" ]
}

@test "disallow of a domain on the default Allowlist fails, saying it's shared by every project" {
  hello_world_exists
  run p4a disallow hello-world github.com
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.com is on the default Allowlist"* ]]
  [[ "$output" == *"share/default-allowlist"* ]]
}

@test "disallow of a domain the project never allowed fails and lists its additions" {
  hello_world_exists
  p4a allow hello-world example.org
  run p4a disallow hello-world example.net
  [ "$status" -eq 1 ]
  [[ "$output" == *"example.net isn't one of hello-world's Allowlist additions"* ]]
  [[ "$output" == *"example.org"* ]]
  [ "$(saved_additions hello-world)" = "example.org" ]
}

@test "new creates the project's Allowlist additions file in the Host config folder, with no additions" {
  sandbox_machine_running
  p4a new octo/hello-world
  [ -f "$P4A_CONFIG_DIR/projects/hello-world.allowlist" ]
  [ -z "$(saved_additions hello-world)" ]
}

@test "a project's Egress proxy reads its Allowlist from a file only p4a writes, and knows its project" {
  sandbox_machine_running
  p4a new octo/hello-world
  local env
  env="$(create_args podman4ai-hello-world-proxy | flag_values --env)"
  has_line "P4A_ALLOWLIST_FILE=$PROXY_ALLOWLIST_FILE" <<< "$env"
  has_line "P4A_PROJECT=hello-world" <<< "$env"
  [ -z "$(grep '^P4A_ALLOWLIST=' <<< "$env")" ]
}

@test "new and start give the Egress proxy its effective Allowlist after starting it and before starting the Sandbox" {
  sandbox_machine_running
  p4a new octo/hello-world
  [ "$(pushed_allowlist podman4ai-hello-world-proxy)" = "$(default_allowlist)" ]
  p4a allow hello-world example.org
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  p4a start hello-world
  [ "$(pushed_allowlist podman4ai-hello-world-proxy)" = "$(default_allowlist; echo example.org)" ]
  [ "$(sandbox_calls | grep -E '^(start|exec podman4ai-hello-world-proxy) ' | cut -d' ' -f1-2)" = "start podman4ai-hello-world-proxy
exec podman4ai-hello-world-proxy
start podman4ai-hello-world" ]
}

@test "start stops the project and fails if the Egress proxy can't be given its Allowlist" {
  hello_world_exists
  fake_podman "--connection podman4ai exec podman4ai-hello-world-proxy" --exit 125
  run p4a start hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't give the Egress proxy podman4ai-hello-world-proxy its Allowlist"* ]]
  [ -z "$(sandbox_calls | grep '^start podman4ai-hello-world$')" ]
  sandbox_calls | has_line "stop podman4ai-hello-world podman4ai-hello-world-proxy"
}

# hello-world's Egress proxy was created before proxies read their
# Allowlist from a file.
hello_world_has_old_proxy() {
  fake_podman "--connection podman4ai container inspect --format {{range .Config.Env}}{{println .}}{{end}} podman4ai-hello-world-proxy" \
    --stdout "P4A_ALLOWLIST=github.com api.anthropic.com"
}

@test "start recreates a stopped Egress proxy made before proxies read an Allowlist file" {
  hello_world_exists
  hello_world_has_old_proxy
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recreating the Egress proxy for hello-world"* ]]
  [ "$(sandbox_calls | grep -E '^(rm|create --name podman4ai-hello-world-proxy |start podman4ai-hello-world-proxy$)' | cut -d' ' -f1-3)" = "rm podman4ai-hello-world-proxy
create --name podman4ai-hello-world-proxy
start podman4ai-hello-world-proxy" ]
  local args
  args="$(create_args podman4ai-hello-world-proxy)"
  has_line "P4A_ALLOWLIST_FILE=$PROXY_ALLOWLIST_FILE" <<< "$(flag_values --env <<< "$args")"
  has_line "--cap-drop=all" <<< "$args"
  has_line "podman4ai-hello-world:ip=10.89.1.2" <<< "$(flag_values --network <<< "$args")"
}

@test "start leaves a running old Egress proxy alone, and says how to update it" {
  hello_world_exists
  hello_world_has_old_proxy
  proxy_running hello-world
  run p4a start hello-world
  [ "$status" -eq 0 ]
  [ -z "$(sandbox_calls | grep -E '^(rm|create) ')" ]
  [[ "$output" == *"p4a stop hello-world"* ]]
}

# hello-world's Egress proxy log.
hello_world_proxy_log() {
  fake_podman "--connection podman4ai logs podman4ai-hello-world-proxy" --stdout "$1"
}

SAMPLE_PROXY_LOG="2026-10-28T10:00:00.000Z listening on port 8888
2026-10-28T10:00:00.010Z allowlist loaded 17 domains
2026-10-28T10:00:01.000Z allowed CONNECT github.com:443
2026-10-28T10:00:02.000Z refused CONNECT pypi.example.net:443 not on the Allowlist
2026-10-28T10:00:03.000Z refused CONNECT example.org:443 not on the Allowlist
2026-10-28T10:00:04.000Z refused GET example.org:80 not on the Allowlist
2026-10-28T10:00:05.000Z refused CONNECT github.com:22 port not allowed
2026-10-28T10:00:06.000Z refused GET / not a proxy request
2026-10-28T10:00:07.000Z refused CONNECT example.org:443 not on the Allowlist
2026-10-28T10:00:08.000Z refused CONNECT cdn.example.info:443 not on the Allowlist
2026-10-28T10:00:09.000Z refused CONNECT cdn.example.info:443 not on the Allowlist"

@test "blocked lists the domains the project's proxy refused, most frequent first, and how to allow one" {
  hello_world_exists
  hello_world_proxy_log "$SAMPLE_PROXY_LOG"
  run p4a blocked hello-world
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Domains the Egress proxy for hello-world refused, most frequent first:" ]
  [ "${lines[1]}" = "  3  example.org" ]
  [ "${lines[2]}" = "  2  cdn.example.info" ]
  [ "${lines[3]}" = "  1  pypi.example.net" ]
  [ "${lines[4]}" = "To let hello-world reach one: p4a allow hello-world <domain>" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "blocked leaves out domains allowed since they were refused" {
  hello_world_exists
  hello_world_proxy_log "$SAMPLE_PROXY_LOG"
  p4a allow hello-world example.org
  p4a allow hello-world '*.example.info'
  run p4a blocked hello-world
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "  1  pypi.example.net" ]
  [[ "$output" != *"example.org"* ]]
  [[ "$output" != *"cdn.example.info"* ]]
}

@test "blocked says so when the proxy hasn't refused any domain" {
  hello_world_exists
  hello_world_proxy_log "2026-10-28T10:00:01.000Z allowed CONNECT github.com:443"
  run p4a blocked hello-world
  [ "$status" -eq 0 ]
  [ "$output" = "The Egress proxy for hello-world hasn't refused any domain." ]
}

@test "blocked needs the Sandbox machine running and a known project" {
  hello_world_exists
  run p4a blocked hello-wrld
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown project 'hello-wrld'"* ]]
  machines "podman4ai hyperv stopped"
  run p4a blocked hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"p4a machine start"* ]]
}

@test "blocked fails clearly when the proxy's log can't be read" {
  hello_world_exists
  fake_podman "--connection podman4ai logs podman4ai-hello-world-proxy" --exit 125 --stderr "Error: no such container"
  run p4a blocked hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"couldn't read the log of the Egress proxy podman4ai-hello-world-proxy"* ]]
}

@test "allow keeps a hand-edited additions file intact, even without a final newline" {
  hello_world_exists
  printf '# my notes\nexample.org  # docs' > "$P4A_CONFIG_DIR/projects/hello-world.allowlist"
  p4a allow hello-world example.net
  [ "$(saved_additions hello-world)" = "example.org
example.net" ]
  grep -qx '# my notes' "$P4A_CONFIG_DIR/projects/hello-world.allowlist"
}

@test "hand-edited additions are matched ignoring case" {
  hello_world_exists
  proxy_running hello-world
  printf 'Example.ORG\n' > "$P4A_CONFIG_DIR/projects/hello-world.allowlist"
  run p4a allow hello-world example.org
  [[ "$output" == *"already allowed"* ]]
  run p4a disallow hello-world example.org
  [ "$status" -eq 0 ]
  [ -z "$(saved_additions hello-world)" ]
}

@test "new refuses to reuse an Allowlist additions file left from an earlier project, and leaves it alone" {
  sandbox_machine_running
  mkdir -p "$P4A_CONFIG_DIR/projects"
  echo "example.org" > "$P4A_CONFIG_DIR/projects/hello-world.allowlist"
  run p4a new octo/hello-world
  [ "$status" -eq 1 ]
  [[ "$output" == *"hello-world.allowlist"* ]]
  [ "$(saved_additions hello-world)" = "example.org" ]
  [ -z "$(sandbox_calls | grep -E '^(create|volume create|network create)')" ]
}

@test "allow says the change is saved when the running proxy can't be given it" {
  hello_world_exists
  proxy_running hello-world
  fake_podman "--connection podman4ai exec podman4ai-hello-world-proxy" --exit 125
  run p4a allow hello-world example.org
  [ "$status" -eq 1 ]
  [[ "$output" == *"saved"* ]]
  [[ "$output" == *"p4a start hello-world"* ]]
  [ "$(saved_additions hello-world)" = "example.org" ]
}
