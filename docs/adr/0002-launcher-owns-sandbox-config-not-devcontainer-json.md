# The Launcher owns Sandbox configuration, not devcontainer.json

Sandboxes are created by podman4ai's Launcher on the Host from configuration kept in this repo, and VS Code only attaches to an already-running Sandbox. We deliberately do not use a per-project `.devcontainer/devcontainer.json`, because an Agent can write to its own repo and could add mounts, capabilities or network changes that the next rebuild would grant. The rule: a Sandbox's boundary is never defined by anything the Agent can write to.

## Consequences

- The same rule covers podman4ai itself: the Launcher you run is an installed clone on the Host that changes only when you pull reviewed changes, never the development copy an Agent edits. Per-project settings live in the Host user config folder, outside every repo.
- Projects may later contribute harmless extras (e.g. VS Code extensions) through a restricted project file, but never mounts, capabilities, network or secrets.
