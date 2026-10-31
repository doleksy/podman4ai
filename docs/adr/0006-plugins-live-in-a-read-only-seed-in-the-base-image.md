# The baseline's plugins live in a read-only seed in the Base image, not in each Claude config volume

The Claude baseline's plugins (context-mode, mattpocock-skills) are downloaded when the Base image is built, into a plugin seed at `/opt/claude-seed` that belongs to root. Claude Code loads them from there in place (`CLAUDE_CODE_PLUGIN_SEED_DIR`) and never writes to it. The rest of the baseline, `images/base/claude-baseline/`, is copied into each Sandbox's Claude config volume when the Sandbox starts, never over a file already there.

## Considered Options

- Plugins installed into `~/.claude/plugins` in the image, copied into each new Claude config volume. That's where Claude Code normally keeps them, but a volume keeps the plugins it started with: a rebuilt image would never update them. An Agent could also change a plugin's code, including its hooks, in its own volume.
- Plugins downloaded when a Sandbox first starts. That needs GitHub's clone traffic, and context-mode's npm installs, on every Sandbox's Allowlist, and a Sandbox would depend on those downloads working.

## Consequences

- Plugins update only when the image is rebuilt and the Sandbox recreated. Claude Code turns auto-update off for a seed.
- Claude Code registers a seed's marketplaces when a session starts. A Sandbox's first interactive session therefore needs `/reload-plugins` once, and `claude plugin list` never shows seed plugins (`/plugin` does).
- Claude Code installs a plugin pinned to a git commit (mattpocock-skills) under its version, but looks for it in a seed under the commit's first 12 hex digits. `p4a-install-plugins` adds that name as a link, or the plugin wouldn't load.
- A plugin that writes into its own folder at runtime can't. context-mode tries at startup, to normalise its hook paths and to fetch a native SQLite binding. Both are optional on Linux: its committed hooks already use plain paths, and it runs on Bun's built-in SQLite. Its doctor passes (test/host/isolation.sh). It prints a note about the binding it couldn't install.
- context-mode still writes in the Claude config volume: its data under `~/.claude/context-mode`, and a SessionStart hook it adds to the volume's `settings.json`. That's per project, like everything else in the volume.
- Plugin sources need only the build Allowlist, never the default Allowlist: GitHub for the plugins, and npm, because installing context-mode runs `npm ci` in its folder. Without npm, that `npm ci` retries for a minute and is left running when the install returns.
