# Prototype: Hyper-V Sandbox machine viability

Evidence behind ADR 0004, gathered for #2 on 2026-10-25.

**Result: Hyper-V confirmed.** The Sandbox machine works on Podman's Hyper-V provider once the one-time admin steps are done, provided the Launcher handles the gaps listed under [Notes for the Launcher](#notes-for-the-launcher).

## Setup

- Windows 10 Pro 19045, Podman 6.1.4 (gvproxy v0.9.0, machine kernel 7.2.5-200.fc44).
- The Hyper-V feature was already enabled before the test (`vmms` service running, hypervisor present).
- `podman-machine-default` (WSL) already existed.
- Throwaway machines, both since removed:
  - `p4a-proto`: Podman's default settings, created in an admin shell.
  - `p4a-novol`: machine volumes emptied, created in a plain shell after joining Hyper-V Administrators.

## One-time admin steps

1. Enable the Hyper-V Windows feature.
2. In an admin PowerShell: `Add-LocalGroupMember -SID S-1-5-32-578 -Member $env:USERNAME` (S-1-5-32-578 is "Hyper-V Administrators").
3. Sign out of Windows and back in. Check with `whoami /groups | findstr /i hyper-v`.

Everything after that, including `podman machine init`, works from a normal shell.

**Correction (found while building #4):** `podman machine init` for the *first* Hyper-V machine (when no other exists) has to add registry entries under `HKLM\...\Virtualization\GuestCommunicationServices`. From a normal shell, Podman relaunches itself elevated to do that (`RelaunchElevatedWait` in Podman's Hyper-V code). The elevated copy doesn't inherit the parent's environment, so `CONTAINERS_CONF_OVERRIDE` is lost and the machine gets the default drive shares. Seven runs confirmed it: the first Hyper-V machine always got the shares, and a second one created while the first existed never did. Removing the last Hyper-V machine removes the entries again. `p4a-novol` most likely came out clean because `p4a-proto` (created in an admin shell) still existed, or its registry entries did.

## 1. Can a non-elevated shell start and stop the machine?

**Only after joining Hyper-V Administrators.**

Before joining the group, a plain shell can't read the machine's state. `podman machine list` warns and shows LAST UP as "Never" even while the machine runs, and `podman machine stop p4a-proto` fails:

```
Error: unable to get state for machine p4a-proto: Hyper-V machines require Hyper-V admin rights to be managed. Please add the current user to the Hyper-V Administrators group or run Podman as an administrator
```

After joining the group and signing back in, `list` shows the real state, and `stop`, `start`, `ssh` and `init` all work from a plain shell.

### Stale socket after sign-out

A Hyper-V VM keeps running when the user signs out, but gvproxy (Podman's Host-side forwarding process) is killed with the session. It leaves `%LOCALAPPDATA%\Temp\podman\<machine>-api.sock` behind. The next start fails:

```
Error: machine did not transition into running state: ssh error: machine is not listening on ssh port
```

`%LOCALAPPDATA%\Temp\podman\gvproxy.log` shows why:

```
gvproxy exiting: error listening on socket: .../podman/p4a-proto-api.sock: bind: Only one usage of each socket address (protocol/network address/port) is normally permitted.
```

The VM itself boots, but nothing listens on the forwarded SSH port. To fix it, stop the machine, delete the `.sock` file, and start it again.

## 2. Does Podman enforce one running machine at a time?

**Only in one direction.**

- WSL machine running, start the Hyper-V machine: refused. Podman doesn't stop the other machine for you.
  ```
  Error: unable to start: podman-machine-default already starting or running on the wsl provider: only one VM can be active at a time
  ```
- Hyper-V machine running, start the WSL machine: **allowed**. Both then show "Currently running" (confirmed with `Get-VM`). This happens both with and without Hyper-V Administrators membership, so it isn't a permissions effect.

Whichever machine starts first claims the default Docker API pipe `npipe:////./pipe/docker_engine`. The second one gets its own pipe (`npipe:////./pipe/podman-machine-default`) and prints a `DOCKER_HOST` hint.

## 3. Are Windows drives exposed to containers?

**Yes, by default. Turning it off is possible only when the machine is created.**

The default machine volumes (`podman machine init --help`) are:

```
C:\Users\<user>:/Users/<user>
C:\:/mnt/c
C:\Users\<user>\AppData\Roaming\containers:/etc/containers
```

On a default Hyper-V machine they're mounted read-write over 9p (`/Users/<user>`, `/var/mnt/c`, `/etc/containers`). They're served by a Host process running as the user: `podman.exe machine server9p --serve C:\Users\<user>:... --serve C:\:... --serve ...\Roaming\containers:...`.

What a guest can do with them:

- Listing directories is denied, even with `sudo`.
- **Reading files by exact path works.** The unprivileged `core` user can `cat /var/mnt/c/Windows/win.ini`. A rootless container given `-v /var/mnt/c:/c:ro -v /Users/<user>:/h:ro` can read `win.ini` and `~/.gitconfig`.
- **Writing works.** A rootless container given `-v /Users/<user>:/h` created a probe file in `%LOCALAPPDATA%\Temp` on the Host (removed afterwards).
- Because of the `/etc/containers` mount, anything in the VM can change the Host's Podman config files in `%APPDATA%\containers`.

`podman machine set` has no volume option, so an existing machine can't be changed. To create a machine without the mounts, point `CONTAINERS_CONF_OVERRIDE` at a file containing:

```toml
[machine]
volumes = []
```

then run `podman machine init --provider hyperv <name>`. On `p4a-novol`, created this way:

- no 9p mounts, and `/var/mnt/c` and `/Users/<user>` don't exist
- no `server9p` process on the Host
- `podman run -v 'C:\Users\<user>:/h:ro' ...` fails with `statfs /mnt/c/Users/<user>: no such file or directory`

## 4. Does selecting the provider per command leave other shells on WSL?

**Yes.**

In a shell that never set `CONTAINERS_MACHINE_PROVIDER`, plain `podman` keeps using the default connection `podman-machine-default-root` (WSL, `127.0.0.1:61444`).

`podman machine start` for a machine that isn't the default asks interactively:

```
Set the default Podman connection to this machine? [y/N]
```

Answering N, or passing `--update-connection=false`, keeps the default unchanged.

In Podman 6, `podman machine start|stop|ssh <name>` find a machine by name across providers without the env var. The provider only matters for `init`, which takes `--provider hyperv`. Podman 6 also dropped `podman machine list --all-providers`, because `list` now shows every provider.

## 5. Networking from a rootless container

**Internet works, and an internal network is cut off.**

Tested on `p4a-novol` (`rootless=true`, the default for a new machine):

| Test | Result |
|---|---|
| Default network, `curl https://example.com` | 200 |
| `--internal` network, `https://example.com` | fails (no name resolution) |
| `--internal` network, `http://1.1.1.1` | could not connect |
| `--internal` network, `host.containers.internal:61444` | could not connect |

## Notes for the Launcher

- Create the Sandbox machine with `--provider hyperv` and machine volumes emptied (see question 3).
- Start it with `--update-connection=false`, and send every call with `--connection <sandbox machine>`.
- Before starting, check for a running WSL machine. Podman won't stop WSL from starting while the Sandbox machine runs, so warn about that case too.
- Remove a stale `<machine>-api.sock` before starting.
- While the Sandbox machine runs, it may own the `docker_engine` pipe, so Docker-compatible tools on the Host reach it by default.
- Set `MSYS_NO_PATHCONV=1`. Git Bash otherwise rewrites `-v /Users/...` into `C:\Program Files\Git\Users\...`.
