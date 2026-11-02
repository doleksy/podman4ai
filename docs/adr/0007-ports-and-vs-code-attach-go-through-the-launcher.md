# Published ports and VS Code attach go through the Launcher

A Sandbox publishes no ports. `p4a port <project> <port>` publishes one by creating a port forwarder: a small container from the Egress proxy image running `images/proxy/port-forward.js`. It sits on Podman's default network and the project's network, is published to `127.0.0.1` on Windows only, and passes each connection to that one port of the Sandbox, at a fixed address (`.3` on the project's network). `p4a unport` removes it. The forwarders are the record of a project's ports: they start and stop with the project, `p4a recreate` recreates them from the current image, and `p4a rm` removes them.

VS Code attaches through `p4a code <project>`, which opens VS Code attached to the Sandbox in its source folder. It checks VS Code's settings first and starts VS Code with Windows' git config switched off, because the Dev Containers extension otherwise hands Windows credentials to anything in the container.

## Considered Options

- **Publish the port on the Sandbox itself** (`podman create --publish 127.0.0.1:P:P`). A port can only be added when a container is created, so every `p4a port` would recreate the Sandbox, ending its Claude session and any dev server. Whether Podman publishes ports from an `--internal` network at all couldn't be checked when this was written.
- **Let VS Code forward ports.** It works only while VS Code is attached, and isn't something the Launcher controls.
- **Attach from VS Code's own menu**, with the Dev Containers settings set by hand. Reading the extension's code (0.469.0) showed this isn't enough. The extension runs a helper in the container that answers `git credential fill` requests with the output of Windows' own git, whatever `dev.containers.gitCredentialHelperConfigLocation` says (that setting only skips writing git config). It also passes the Windows ssh-agent through whenever `SSH_AUTH_SOCK` is set or the Windows OpenSSH agent's pipe exists, and no setting turns that off.

## Consequences

- A server in the Sandbox must listen on `0.0.0.0`, not just `127.0.0.1`, to be reachable. The forwarder logs each connection it couldn't make, saying so (`p4a podman logs podman4ai-<project>-port-<port>`).
- The forwarder is on Podman's default network, like the Egress proxy, but only ever connects to its Sandbox's one port. The Sandbox can't use it to reach anything else: it has no route through it.
- Sandboxes created before this need `p4a recreate` to get their fixed address. Egress proxy images built before it have no forwarder, so `p4a port` says to rebuild them with `p4a image build`.
- `p4a code` refuses until VS Code's user settings have `dockerPath` `podman`, `copyGitConfig` false, `gitCredentialHelperConfigLocation` `none` and `dockerCredentialHelper` false. It starts VS Code with `CONTAINER_CONNECTION` set to the Sandbox machine (so VS Code's `podman` finds it without changing the default connection), `GIT_CONFIG_NOSYSTEM=1`, an empty `GIT_CONFIG_GLOBAL` (so Windows git has no credential helper and credential requests come back empty), and no `SSH_AUTH_SOCK`, `SSH_ASKPASS` or `GIT_ASKPASS` (Git Bash sets `SSH_ASKPASS`; with it, a credential request from the Sandbox popped up a password prompt on Windows).
- **Accepted residual risks.** The guard relies on VS Code giving the window the environment of the `code` command that opened it; `docs/vscode.md` has a check for it. A window opened any other way (VS Code's own attach menu, or one restored after a restart) doesn't have that environment. While the Windows OpenSSH agent is running, an Agent can use its keys through VS Code; `p4a code` warns when it is. A Sandbox can open URLs in the Windows browser and make VS Code forward its ports to Windows localhost, as with any attached container.
