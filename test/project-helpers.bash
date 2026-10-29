# Shared setup for the tests of projects: a Sandbox machine whose fake
# podman lets p4a new, start and the Allowlist commands succeed, and ways
# to read back what p4a asked Podman to do.

load helpers

# The calls p4a made to Podman inside the Sandbox machine, without the
# leading "--connection podman4ai".
sandbox_calls() {
  podman_calls_starting "--connection podman4ai " | sed 's/^--connection podman4ai //'
}

# The Sandbox machine is running, and every Sandbox's self-check passes:
# an allowlisted domain is reachable and example.com is not.
sandbox_machine_running() {
  machines "podman4ai hyperv running"
  # No project's parts exist yet.
  fake_podman "--connection podman4ai volume exists" --exit 1
  fake_podman "--connection podman4ai network exists" --exit 1
  fake_podman "--connection podman4ai container exists" --exit 1
  # The Agent token is set, and so is every project's Repo token.
  fake_podman "--connection podman4ai secret exists" --exit 0
  # Every secret's current ID.
  fake_podman "--connection podman4ai secret inspect --format {{.ID}}" --stdout id-1
  # Every Egress proxy reads its Allowlist from the file p4a writes.
  fake_podman "--connection podman4ai container inspect --format {{range .Config.Env}}{{println .}}{{end}}"     --stdout "P4A_ALLOWLIST_FILE=/home/node/allowlist"
  # The developer's git identity on the Host.
  git config --global user.name "Dev Example"
  git config --global user.email "dev@example.com"
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://example.com" --exit 56
  fake_podman "--connection podman4ai exec podman4ai-spoon-knife curl https://example.com" --exit 56
}

# The project hello-world exists.
hello_world_exists() {
  sandbox_machine_running
  p4a new octo/hello-world
  : > "$FAKE_PODMAN_DIR/calls.jsonl"
  # Its Sandbox mounts the current tokens.
  fake_podman "--connection podman4ai container inspect --format {{range .Config.Secrets}}{{.Name}}={{.ID}}{{println}}{{end}} podman4ai-hello-world" \
    --stdout "podman4ai-agent-token=id-1
podman4ai-hello-world-repo-token=id-1"
}

# The arguments of the call that created CONTAINER, one per line.
create_args() {
  _calls "c.args[2] === \"create\" && c.args.includes(\"--name\") && c.args[c.args.indexOf(\"--name\") + 1] === \"$1\" ? c.args.slice(2).join(\"\\n\") : null"
}

# Fail unless the lines on stdin include LINE exactly.
has_line() {
  grep -qxF -- "$1"
}

# The values of FLAG (as --flag=value or --flag value) in the args on stdin.
flag_values() {
  awk -v f="$1" '$0 == f { getline; print; next } index($0, f "=") == 1 { print substr($0, length(f) + 2) }'
}
