#!/usr/bin/env bats
# p4a secret set: storing the Agent token and Repo tokens.

load helpers

# Print the stdin each `secret create` call received, one call per line.
secret_create_stdin() {
  _calls 'c.args.includes("create") && c.args.includes("secret") ? JSON.stringify(c.stdin) : null'
}

@test "secret set agent-token stores the value from stdin as a Podman secret, never as an argument" {
  machines "podman4ai hyperv running"
  run p4a secret set agent-token <<< "sk-ant-oat01-canary"
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting '--connection podman4ai secret create')" = "--connection podman4ai secret create --replace podman4ai-agent-token -" ]
  [ "$(secret_create_stdin)" = '"sk-ant-oat01-canary"' ]
  [[ "$output" != *"sk-ant-oat01-canary"* ]]
  [[ "$output" == *"Stored the Agent token"* ]]
}

@test "secret set repo-token stores a project's own Repo token, before or after p4a new" {
  machines "podman4ai hyperv running"
  run p4a secret set repo-token hello-world <<< "github_pat_canary"
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting '--connection podman4ai secret create')" = "--connection podman4ai secret create --replace podman4ai-hello-world-repo-token -" ]
  [ "$(secret_create_stdin)" = '"github_pat_canary"' ]
  [[ "$output" != *"github_pat_canary"* ]]
  [[ "$output" == *"Stored the Repo token for hello-world"* ]]
}

@test "secret set repo-token needs a valid project name" {
  machines "podman4ai hyperv running"
  for args in "repo-token" "repo-token Hello/World" "repo-token a b"; do
    run p4a secret set $args <<< "github_pat_canary"
    [ "$status" -eq 2 ]
    [[ "$output" == *"p4a secret --help"* ]]
  done
  [ -z "$(podman_calls_starting '--connection podman4ai secret')" ]
}

@test "an empty value stores nothing" {
  machines "podman4ai hyperv running"
  run p4a secret set agent-token <<< "   "
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing was stored"* ]]
  [ -z "$(podman_calls_starting '--connection podman4ai secret')" ]
}

@test "token values never appear in any Podman argument or environment, only on secret create's stdin" {
  machines "podman4ai hyperv running"
  fake_podman "--connection podman4ai volume exists" --exit 1
  fake_podman "--connection podman4ai network exists" --exit 1
  fake_podman "--connection podman4ai container exists" --exit 1
  fake_podman "--connection podman4ai secret exists" --exit 0
  fake_podman "--connection podman4ai exec podman4ai-hello-world curl https://example.com" --exit 56
  fake_podman "--connection podman4ai container inspect --format {{.State.Running}} podman4ai-hello-world" --stdout true
  git config --global user.name "Dev Example"
  git config --global user.email "dev@example.com"

  p4a secret set agent-token <<< "sk-ant-oat01-agentcanary"
  p4a secret set repo-token hello-world <<< "github_pat_repocanary"
  p4a new octo/hello-world
  p4a start hello-world
  p4a shell hello-world -- claude -p "say hello"

  [ "$(_calls '1' | wc -l)" -gt 10 ]
  local leaks
  leaks="$(_calls 'JSON.stringify([c.args, c.allEnv]).match(/agentcanary|repocanary/) ? c.args.join(" ") : null')"
  [ -z "$leaks" ]
  # Each value went to Podman exactly once, on stdin.
  [ "$(_calls 'c.stdin && /canary/.test(c.stdin) ? c.args.join(" ") : null')" = "--connection podman4ai secret create --replace podman4ai-agent-token -
--connection podman4ai secret create --replace podman4ai-hello-world-repo-token -" ]
}
