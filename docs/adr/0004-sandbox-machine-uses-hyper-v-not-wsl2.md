# The Sandbox machine uses Hyper-V, not WSL2

Podman on Windows defaults to WSL2, but every WSL2 distro shares one Linux kernel, other distros can alter shared kernel settings, and root inside a distro can likely re-mount Windows drives even with automount disabled. We run the Sandbox machine on Podman's Hyper-V provider instead, so it has its own kernel and no built-in path to the Host's drives or programs. Since Project volumes mean nothing needs Windows file access (ADR 0001), WSL2's main advantage doesn't apply.

## Considered Options

- WSL2 machine with automount and interop disabled: easier, kept as the fallback if Hyper-V proves unworkable on Windows 10 Pro.

## Status

Confirmed by the Hyper-V prototype (#2) on Windows 10 Pro with Podman 6.1.4. Evidence: [docs/prototypes/hyper-v.md](../prototypes/hyper-v.md).

## Consequences

- Setup needs admin rights once: enable the Hyper-V feature and add the user to the "Hyper-V Administrators" group, then sign out and back in. After that, starting, stopping and entering the Sandbox machine all work from a normal shell. Without the group, Podman can't even read the machine's state.
- Creating the Sandbox machine also needs an admin shell when no other Hyper-V machine exists. Podman then has to add shared registry entries, so from a normal shell it relaunches itself elevated, and that copy doesn't inherit `CONTAINERS_CONF_OVERRIDE` (below). The Launcher checks the new machine's mounts after creating it, and removes it if any Windows drive is shared.
- Podman's defaults share Windows drives with a Hyper-V machine (the user's home, all of `C:\`, and `%APPDATA%\containers` over 9p), and containers can read and write Host files through them. The Launcher creates the Sandbox machine with machine volumes emptied (`[machine] volumes = []` via `CONTAINERS_CONF_OVERRIDE`). This can't be changed on an existing machine, so a machine created any other way must be recreated.
- Podman only partly enforces one running machine. Starting the Sandbox machine while `podman-machine-default` runs is refused, but starting the WSL machine while the Sandbox machine runs is allowed, and then both run at once. The Launcher checks for other running machines itself and doesn't rely on Podman.
- The Launcher sends its own `podman` calls to the Sandbox machine with `--connection`, and starts it with `--update-connection=false`, so the default connection, and other Podman use, stays on WSL2.
- Whichever machine starts first claims the default Docker API pipe (`docker_engine`), so while the Sandbox machine runs, Docker-compatible tools on the Host reach it by default.
- The Hyper-V VM keeps running when the user signs out, but Podman's helper process (gvproxy) doesn't, leaving a stale `%LOCALAPPDATA%\Temp\podman\<machine>-api.sock`. The next start then fails with "machine is not listening on ssh port". The Launcher removes a stale socket before starting.
- After a Windows restart the Sandbox machine can be running without gvproxy, though Podman already sets the VM's Hyper-V automatic start action to "Nothing", so the cause isn't known yet. Podman then lists it as running, but every Podman call is refused. The Launcher checks that Podman answers before each command that needs the Sandbox machine, and says to stop and start it.
- Machine memory is a fixed allocation rather than WSL's on-demand growth.
