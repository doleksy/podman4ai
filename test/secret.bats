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

@test "secret --help lists the Repo token's required permissions and points to the README for the optional ones" {
  run p4a secret --help
  [ "$status" -eq 0 ]
  # The help wraps, so compare with line breaks and indents folded to spaces.
  local help
  help=$(tr -s ' \n' '  ' <<< "$output")
  [[ "$help" == *"Contents, Pull requests and Issues, each Read and write"* ]]
  [[ "$help" == *"README"* && "$help" == *"optional permissions"* ]]
}

@test "secret set repo-token stores a project's own Repo token, labelled with its project and name, before or after p4a new" {
  machines "podman4ai hyperv running"
  run p4a secret set repo-token hello-world <<< "github_pat_canary"
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting '--connection podman4ai secret create')" = "--connection podman4ai secret create --replace --label podman4ai.project=hello-world --label podman4ai.secret-name=repo-token podman4ai.hello-world.repo-token -" ]
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
--connection podman4ai secret create --replace --label podman4ai.project=hello-world --label podman4ai.secret-name=repo-token podman4ai.hello-world.repo-token -" ]
}

@test "secret set refuses before reading a value when Podman in the Sandbox machine doesn't answer" {
  machines "podman4ai hyperv running"
  podman_not_answering
  for args in "agent-token" "repo-token hello-world"; do
    run p4a secret set $args <<< "sk-ant-oat01-canary"
    [ "$status" -eq 1 ]
    [[ "$output" == *"doesn't answer"* ]]
    [[ "$output" == *"p4a machine stop"*"p4a machine start"* ]]
  done
  # Had it read the value first, it would have tried to store it.
  [ -z "$(podman_calls_starting '--connection podman4ai secret create')" ]
}

@test "secret set stores any Project secret by name, labelled with its project and name, from stdin only" {
  machines "podman4ai hyperv running"
  run p4a secret set mouser-api-key hello-world <<< "mouser_canary"
  [ "$status" -eq 0 ]
  [ "$(podman_calls_starting '--connection podman4ai secret create')" = "--connection podman4ai secret create --replace --label podman4ai.project=hello-world --label podman4ai.secret-name=mouser-api-key podman4ai.hello-world.mouser-api-key -" ]
  [ "$(secret_create_stdin)" = '"mouser_canary"' ]
  [ -z "$(_calls 'JSON.stringify([c.args, c.allEnv]).includes("mouser_canary") ? c.args.join(" ") : null')" ]
  [[ "$output" != *"mouser_canary"* ]]
  [[ "$output" == *"Stored the secret mouser-api-key for hello-world"* ]]
  [[ "$output" == *"p4a new will use it"* ]]
}

@test "secret set says a project's Sandbox uses a new Project secret once restarted" {
  machines "podman4ai hyperv running"
  mkdir -p "$P4A_CONFIG_DIR/projects"
  : > "$P4A_CONFIG_DIR/projects/hello-world.conf"
  run p4a secret set mouser-api-key hello-world <<< "mouser_canary"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Its Sandbox uses it once restarted: p4a stop hello-world, then p4a start hello-world."* ]]
}

@test "secret set needs a valid secret name and one project, and agent-token takes no project" {
  machines "podman4ai hyperv running"
  for args in "" "Mouser-Key hello-world" "mouser.key hello-world" "-mouser hello-world" "mouser_key hello-world" \
      "mouser-api-key" "mouser-api-key Hello/World" "mouser-api-key a b" "agent-token hello-world"; do
    run p4a secret set $args <<< "mouser_canary"
    [ "$status" -eq 2 ]
    [[ "$output" == *"p4a secret --help"* ]]
  done
  [ -z "$(podman_calls_starting '--connection podman4ai secret')" ]
}

@test "secret set of a Project secret stores nothing for an empty value, and refuses before reading one when Podman doesn't answer" {
  machines "podman4ai hyperv running"
  run p4a secret set mouser-api-key hello-world <<< "   "
  [ "$status" -eq 1 ]
  [[ "$output" == *"no secret mouser-api-key for hello-world entered, so nothing was stored"* ]]
  [ -z "$(podman_calls_starting '--connection podman4ai secret')" ]
  podman_not_answering
  run p4a secret set mouser-api-key hello-world <<< "mouser_canary"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't answer"* ]]
  [ -z "$(podman_calls_starting '--connection podman4ai secret create')" ]
}

@test "secret set of a Project secret refuses before reading a value when the Sandbox machine isn't running" {
  machines "podman4ai hyperv stopped"
  run p4a secret set mouser-api-key hello-world <<< "mouser_canary"
  [ "$status" -eq 1 ]
  [ -z "$(podman_calls_starting '--connection podman4ai secret')" ]
}

@test "secret --help describes Project secrets, their name rules and when a Sandbox gets them" {
  run p4a secret --help
  [ "$status" -eq 0 ]
  local help
  help=$(tr -s ' \n' '  ' <<< "$output")
  [[ "$help" == *"p4a secret set <name> <project>"* ]]
  [[ "$help" == *"/run/secrets/<name>"* ]]
  [[ "$help" == *"lower-case letters, digits and hyphens"* ]]
  [[ "$help" == *"agent-token"*"reserved"* ]]
  [[ "$help" == *"p4a stop"*"p4a start"* ]]
  [[ "$help" == *"never recreates a running Sandbox"* ]]
}
