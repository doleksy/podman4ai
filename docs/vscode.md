# Editing in VS Code, and viewing a dev server

VS Code's interface runs on Windows and its engine (the VS Code server, extensions, terminal, git) runs inside the Sandbox, as the user `agent`, against the source in the Project volume (ADR 0001). Always attach with `p4a code`: it keeps Windows' credentials out of the Sandbox (ADR 0007).

## Setup

1. Install [VS Code](https://code.visualstudio.com) with **Add to PATH** ticked. Nothing else: `p4a code` sets up the rest.
2. Don't run the Windows OpenSSH agent while VS Code is attached to a Sandbox: VS Code passes it in, and nothing turns that off, so an Agent could use your SSH keys. Check with `Get-Service ssh-agent` in PowerShell; `p4a code` warns when it's running.

### A VS Code of its own

`p4a code` runs a VS Code of its own, apart from your everyday one: its own settings, sign-ins, extensions and remembered windows, in `%APPDATA%\podman4ai\vscode\` (VS Code's `--user-data-dir` and `--extensions-dir`). So:

- None of your everyday sign-ins reach a Sandbox. VS Code hands its GitHub sign-in to extensions running in a container, so with your everyday VS Code, an extension in a Sandbox could use your GitHub account, not just the project's Repo token. Don't sign in to anything in `p4a code`'s VS Code.
- Your everyday extensions don't follow you in. By default VS Code installs GitHub Copilot and Pull Requests into every container they're installed locally for (`remote.defaultExtensionsIfInstalledLocally`).
- Your everyday VS Code never opens or restores a Sandbox window without `p4a code`'s protections.

The first `p4a code` installs Dev Containers there and writes its settings file, `%APPDATA%\podman4ai\vscode\data\User\settings.json`:

```jsonc
"dev.containers.dockerPath": "podman",
"dev.containers.copyGitConfig": false,
"dev.containers.gitCredentialHelperConfigLocation": "none",
"dev.containers.dockerCredentialHelper": false,
"remote.defaultExtensionsIfInstalledLocally": [],
```

The first lets VS Code use Podman. The next three stop VS Code copying your Windows git config into the Sandbox and setting up its git and Docker credential helpers there. The last stops it copying extensions in. Add anything else you like (a theme, say): `p4a code` keeps your changes, but refuses to start if one of these is missing or changed, and names it.

## Attaching

```bash
p4a code hello-world
```

This starts the project if it's stopped, then opens a window of `p4a code`'s VS Code attached to its Sandbox, in the source folder (`/workspace/<repo>`). The first time, VS Code asks you to confirm that attaching may run code in the container: accept. It then puts its server in the Sandbox; Dev Containers downloads it on Windows and copies it in. Terminals in that window run in the Sandbox as `agent`. Extensions you install there are installed in the Sandbox, and kept until it's recreated.

VS Code finds the Sandbox machine because `p4a code` sets `CONTAINER_CONNECTION=podman4ai` for it; plain `podman` elsewhere keeps its own default. Only open Sandboxes with `p4a code`, never from your everyday VS Code's **Attach to Running Container** menu: that VS Code has your sign-ins and extensions, and doesn't get `p4a code`'s protections, so it can hand the Sandbox your Windows git credentials (see below).

If VS Code can't download something, see what the Egress proxy refused with `p4a blocked hello-world`, and allow it with `p4a allow`. The default Allowlist has VS Code's update server, download CDN and extension marketplace.

### Checking Windows credentials stay out

The Dev Containers extension runs a helper in the container that asks Windows' git for credentials, and the settings above don't turn it off. `p4a code` starts VS Code with Windows' git config switched off (`GIT_CONFIG_NOSYSTEM=1` and an empty `GIT_CONFIG_GLOBAL`), so Windows git has no credential helper and every request comes back empty. This relies on VS Code giving the new window the environment of the `code` command that opened it. Check it once, and after VS Code updates, in a terminal in the attached window:

```bash
helper="$(ls /tmp/vscode-remote-containers-*.js | grep -v -- -server- | head -1)"
printf 'protocol=https\nhost=github.com\n\n' | node "$helper" git-credential-helper get
```

It must print no `password=` line. If it prints one, close the window and don't attach VS Code to Sandboxes until it's fixed.

## Viewing a dev server

A Sandbox publishes no ports. To reach one from a Windows browser:

```bash
p4a port hello-world 3000      # publish port 3000 at http://localhost:3000
p4a port hello-world           # list the ports it publishes
p4a unport hello-world 3000    # stop publishing it
```

The port is published on Windows' `127.0.0.1` only, so no other device on the network can reach it. The server in the Sandbox must listen on `0.0.0.0`, not just `127.0.0.1`: for example `npm run dev -- --host 0.0.0.0` for Vite, or `python -m http.server 3000 --bind 0.0.0.0`. If the page doesn't load, the forwarder's log says why: `p4a podman logs podman4ai-hello-world-port-3000`.

A published port stays published across `p4a stop`, `p4a start` and `p4a recreate`, and is removed by `p4a rm`. If a Windows program already uses the port, `p4a port` says so and publishes nothing. `p4a port` needs a Sandbox created by this version of podman4ai, with a fixed address (otherwise it says to run `p4a recreate`), and an Egress proxy image built by it (otherwise it says to run `p4a image build`).

VS Code may also offer to forward ports itself while attached. That works too, but only while the window is open.
