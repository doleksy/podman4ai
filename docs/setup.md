# Setting up podman4ai

This takes a fresh Windows 10 Pro (or 11 Pro) machine to a working Sandbox. The admin steps happen once. Everything after them runs from a normal Git Bash. The admin steps come from the Hyper-V prototype ([prototypes/hyper-v.md](prototypes/hyper-v.md)).

## 1. Install the Host programs

In PowerShell:

```powershell
winget install --id Git.Git           # Git for Windows, which brings Git Bash and ssh
winget install --id RedHat.Podman     # Podman 6 or later
irm https://claude.ai/install.ps1 | iex   # Claude Code, only for 'claude setup-token' in step 6
```

Optional:

- VS Code, for `p4a code` (see [vscode.md](vscode.md)): `winget install --id Microsoft.VisualStudioCode`, with **Add to PATH** ticked.
- Node and shellcheck, to run the unit tests on the Host: `winget install --id OpenJS.NodeJS.LTS` and `winget install --id koalaman.shellcheck`.

You don't need a Podman machine of your own: `p4a` makes the Sandbox machine on Hyper-V. An existing one (such as Podman's default WSL machine) is fine, but Podman runs one machine at a time, so stop it while the Sandbox machine runs.

Then close PowerShell. Programs you just installed are only on the PATH of shells opened after the install.

## 2. The one-time admin steps

Hyper-V needs Windows Pro, Enterprise or Education, and virtualization turned on in the firmware (Task Manager, Performance, CPU shows **Virtualization: Enabled**).

1. In an admin PowerShell, enable Hyper-V, then restart Windows:

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
   ```

2. In an admin PowerShell, join "Hyper-V Administrators", so a normal shell can start and stop the Sandbox machine:

   ```powershell
   Add-LocalGroupMember -SID S-1-5-32-578 -Member $env:USERNAME
   ```

3. Sign out of Windows and back in. Check with `whoami /groups | findstr /i hyper-v`.

## 3. Install the Launcher

Install `p4a` from its own clone, which you only ever update by pulling reviewed, merged changes. Never put a copy an Agent edits on your PATH (ADR 0002). `p4a` uses the files next to it, so editing any other copy doesn't change it. In Git Bash:

```bash
git clone https://github.com/doleksy/podman4ai.git ~/podman4ai
echo 'export PATH="$HOME/podman4ai/bin:$PATH"' >> ~/.bashrc
git config --global user.name "Your Name"      # commits made in Sandboxes carry these
git config --global user.email you@example.com
```

Close Git Bash and open a new one, so it reads `~/.bashrc`. Check with `p4a --help`.

## 4. Create the Sandbox machine (admin, once)

Open Git Bash with **Run as administrator** and run:

```bash
p4a machine create
```

It needs admin only this first time: from a normal shell, Podman relaunches itself as administrator to create the first Hyper-V machine, and the relaunched copy shares your Windows drives with it. If you run it from a normal shell anyway, `p4a` notices the shared drives, removes the machine and asks you to rerun it as administrator.

Close the admin Git Bash. From here on, use a normal one.

## 5. Start it and build the images

```bash
p4a machine start
p4a image build
```

The build takes several minutes. It ends by listing the domains it reached and any it was refused.

## 6. Store the tokens

```bash
claude setup-token          # on the Host, once: prints the Agent token, valid a year
p4a secret set agent-token  # paste it at the hidden prompt
```

For a repository the Agent should push to, or a private one, the project needs a Repo token: make a [fine-grained token](https://github.com/settings/personal-access-tokens/new) for that one repository, with read and write access to Contents, Pull requests and Issues, and store it before creating the project:

```bash
p4a secret set repo-token <project>   # the project is the repository name, lower case
```

## 7. Create a project and start working

```bash
p4a new <owner/repo>
p4a claude <project>
```

You're in Claude Code, inside the project's Sandbox. See the [tmux cheat sheet](tmux.md) for leaving and coming back.

To check the isolation on this machine, run the integration tests from the installed clone (several minutes):

```bash
~/podman4ai/test/host/isolation.sh
```

## Updating

```bash
git -C ~/podman4ai pull --ff-only
```

If the update changed anything under `images/`, rebuild them and move every project onto them:

```bash
p4a image build
p4a recreate --all
```

## After a Windows restart, or when something's off

`p4a machine status` says what's wrong and how to fix it. The usual fix is `p4a machine stop`, then `p4a machine start`.
