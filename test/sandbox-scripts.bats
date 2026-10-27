#!/usr/bin/env bats
# The Base image's sign-in scripts, run here against a stand-in secrets
# folder (the Sandbox's /run/secrets).

SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../images/base" && pwd)"

setup() {
  export P4A_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  mkdir -p "$P4A_SECRETS_DIR"
  export P4A_PROJECT=hello-world
  unset CLAUDE_CODE_OAUTH_TOKEN
}

# The value of CLAUDE_CODE_OAUTH_TOKEN that a command run by p4a-session
# sees, or <unset>.
session_token() {
  sh "$SCRIPTS/p4a-session" sh -c 'echo "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"'
}

@test "p4a-session hands the Agent token file to Claude Code, then runs the command" {
  printf 'sk-ant-oat01-abc\n' > "$P4A_SECRETS_DIR/agent-token"
  [ "$(session_token)" = "sk-ant-oat01-abc" ]
  run sh "$SCRIPTS/p4a-session" sh -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "p4a-session without an Agent token runs the command without one" {
  [ "$(session_token)" = "<unset>" ]
}

# Ask the credential helper for github.com credentials.
credential_get() {
  printf 'protocol=https\nhost=github.com\n\n' | sh "$SCRIPTS/p4a-git-credential" get
}

@test "the git credential helper answers with the Repo token" {
  printf 'github_pat_abc\n' > "$P4A_SECRETS_DIR/repo-token"
  run credential_get
  [ "$status" -eq 0 ]
  [ "$output" = "username=x-access-token
password=github_pat_abc" ]
}

@test "with no Repo token, the git credential helper says how to set one and stops git asking" {
  echo > "$P4A_SECRETS_DIR/repo-token"
  local out err
  out="$(credential_get 2> "$BATS_TEST_TMPDIR/err")"
  err="$(cat "$BATS_TEST_TMPDIR/err")"
  [ "$out" = "quit=1" ]
  [[ "$err" == *"no Repo token"* ]]
  [[ "$err" == *"p4a secret set repo-token hello-world"* ]]
}

@test "the git credential helper ignores store and erase" {
  printf 'github_pat_abc\n' > "$P4A_SECRETS_DIR/repo-token"
  for action in store erase; do
    run sh "$SCRIPTS/p4a-git-credential" "$action" <<< "host=github.com"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}
