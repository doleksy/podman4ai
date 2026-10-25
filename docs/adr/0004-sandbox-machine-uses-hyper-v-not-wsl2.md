# The Sandbox machine uses Hyper-V, not WSL2

Podman on Windows defaults to WSL2, but every WSL2 distro shares one Linux kernel, other distros can alter shared kernel settings, and root inside a distro can likely re-mount Windows drives even with automount disabled. We run the Sandbox machine on Podman's Hyper-V provider instead, so it has its own kernel and no built-in path to the Host's drives or programs. Since Project volumes mean nothing needs Windows file access (ADR 0001), WSL2's main advantage doesn't apply.

## Considered Options

- WSL2 machine with automount and interop disabled: easier, kept as the fallback if Hyper-V proves unworkable on Windows 10 Pro.

## Consequences

- The Launcher selects the Hyper-V provider only for its own `podman` calls; other Podman use stays on WSL2.
- Podman runs one machine at a time, so the Sandbox machine and `podman-machine-default` don't run simultaneously.
- Initial setup needs admin rights (Hyper-V feature, machine creation).
- Machine memory is a fixed allocation rather than WSL's on-demand growth.
