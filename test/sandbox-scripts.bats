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

# A stand-in Claude baseline (in the image, /usr/local/share/podman4ai/
# claude-baseline) and Claude config volume (~/.claude) for p4a-entrypoint.
baseline_setup() {
  export P4A_CLAUDE_BASELINE="$BATS_TEST_TMPDIR/baseline"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$P4A_CLAUDE_BASELINE" "$CLAUDE_CONFIG_DIR"
  echo '{"theme":"dark"}' > "$P4A_CLAUDE_BASELINE/settings.json"
  echo '# baseline notes' > "$P4A_CLAUDE_BASELINE/CLAUDE.md"
}

@test "p4a-entrypoint puts the Claude baseline in a new Claude config volume, then runs the command" {
  baseline_setup
  run sh "$SCRIPTS/p4a-entrypoint" sh -c 'echo started; exit 7'
  [ "$status" -eq 7 ]
  [ "$output" = started ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = '{"theme":"dark"}' ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" = '# baseline notes' ]
}

@test "p4a-entrypoint never overwrites what the Sandbox has changed, but restores a deleted baseline file" {
  baseline_setup
  echo '{"theme":"light"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-workspace-a/memory"
  echo 'a memory' > "$CLAUDE_CONFIG_DIR/projects/-workspace-a/memory/MEMORY.md"
  run sh "$SCRIPTS/p4a-entrypoint" true
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = '{"theme":"light"}' ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/projects/-workspace-a/memory/MEMORY.md")" = 'a memory' ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" = '# baseline notes' ]
}

@test "p4a-entrypoint still runs the command if the baseline can't be copied, and says so" {
  baseline_setup
  rm -r "$CLAUDE_CONFIG_DIR"
  touch "$CLAUDE_CONFIG_DIR"
  local out
  out="$(sh "$SCRIPTS/p4a-entrypoint" echo started 2> "$BATS_TEST_TMPDIR/err")"
  [ "$out" = started ]
  [[ "$(cat "$BATS_TEST_TMPDIR/err")" == *"couldn't copy the Claude baseline"* ]]
}

# A stand-in for Claude Code that logs each call, one line each:
# the plugins folder it would use | its config folder | its arguments.
fake_claude() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'FAKE'
#!/bin/sh
echo "$CLAUDE_CODE_PLUGIN_CACHE_DIR|$CLAUDE_CONFIG_DIR|$*" >> "$CLAUDE_LOG"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  : > "$CLAUDE_LOG"
}

@test "p4a-install-plugins adds the baseline's marketplaces and installs its enabled plugins into the seed" {
  fake_claude
  cat > "$BATS_TEST_TMPDIR/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "skills@official": true,
    "unwanted@official": false,
    "tool@tools": true
  },
  "extraKnownMarketplaces": {
    "official": { "source": { "source": "github", "repo": "example/official" } },
    "tools": { "source": { "source": "github", "repo": "example/tools" } }
  }
}
JSON
  local seed="$BATS_TEST_TMPDIR/seed"
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$seed"
  [ "$status" -eq 0 ]
  [ "$(cut -d'|' -f1,3 "$CLAUDE_LOG")" = "$seed|plugin marketplace add example/official
$seed|plugin marketplace add example/tools
$seed|plugin install skills@official
$seed|plugin install tool@tools" ]
}

# A baseline settings.json with one marketplace and one plugin.
one_plugin_settings() {
  cat > "$BATS_TEST_TMPDIR/settings.json" <<'JSON'
{
  "enabledPlugins": { "tool@tools": true },
  "extraKnownMarketplaces": {
    "tools": { "source": { "source": "github", "repo": "example/tools" } }
  }
}
JSON
}

@test "p4a-install-plugins gives Claude Code a throwaway config folder, and removes it" {
  fake_claude
  one_plugin_settings
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$BATS_TEST_TMPDIR/seed"
  [ "$status" -eq 0 ]
  local configs
  configs="$(cut -d'|' -f2 "$CLAUDE_LOG" | sort -u)"
  [ "$(wc -l <<< "$configs")" -eq 1 ]
  [ -n "$configs" ]
  [ "$configs" != "$HOME/.claude" ]
  [ ! -e "$configs" ]
}

@test "p4a-install-plugins fails if a marketplace or plugin doesn't install" {
  fake_claude
  one_plugin_settings
  printf '#!/bin/sh\necho "$*" >> "$CLAUDE_LOG"\n[ "$2" != install ]\n' > "$BATS_TEST_TMPDIR/bin/claude"
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$BATS_TEST_TMPDIR/seed"
  [ "$status" -ne 0 ]
  printf '#!/bin/sh\necho "$*" >> "$CLAUDE_LOG"\n[ "$2" != marketplace ]\n' > "$BATS_TEST_TMPDIR/bin/claude"
  : > "$CLAUDE_LOG"
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$BATS_TEST_TMPDIR/seed"
  [ "$status" -ne 0 ]
  [ "$(cat "$CLAUDE_LOG")" = "plugin marketplace add example/tools" ]
}

@test "p4a-install-plugins refuses a marketplace that isn't on GitHub, installing nothing" {
  fake_claude
  echo '{"extraKnownMarketplaces": {"local": {"source": {"source": "directory", "path": "/x"}}}}' \
    > "$BATS_TEST_TMPDIR/settings.json"
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$BATS_TEST_TMPDIR/seed"
  [ "$status" -ne 0 ]
  [[ "$output" == *"marketplace local must have a GitHub source"* ]]
  [ ! -s "$CLAUDE_LOG" ]
}

# Claude Code installs a plugin pinned to a git commit under its version
# (cache/MARKETPLACE/PLUGIN/VERSION), but looks for it in a seed under the
# commit's first 12 hex digits, so it doesn't load from the seed.
@test "p4a-install-plugins makes each installed plugin findable in the seed under its commit too" {
  fake_claude
  one_plugin_settings
  local seed="$BATS_TEST_TMPDIR/seed"
  mkdir -p "$seed/cache/tools/tool/1.3.1"
  echo skill > "$seed/cache/tools/tool/1.3.1/SKILL.md"
  cat > "$seed/installed_plugins.json" <<'JSON'
{ "version": 2, "plugins": { "tool@tools": [ {
  "installPath": "/opt/claude-seed/cache/tools/tool/1.3.1", "version": "1.3.1",
  "gitCommitSha": "49dd158d1076134a641b33efb035946536778336" } ] } }
JSON
  run sh "$SCRIPTS/p4a-install-plugins" "$BATS_TEST_TMPDIR/settings.json" "$seed"
  [ "$status" -eq 0 ]
  [ "$(cat "$seed/cache/tools/tool/49dd158d1076/SKILL.md")" = skill ]
}
