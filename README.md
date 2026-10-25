# podman4ai

A secure environment on a Windows workstation where all AI agent work happens inside Podman containers, isolated from the Host and from other projects. Vocabulary: [GLOSSARY.md](GLOSSARY.md). Decisions: [docs/adr/](docs/adr/).

## The Launcher: `p4a`

`p4a` is a Bash program run from Git Bash on the Host. Run it from an installed clone that you only update by pulling reviewed changes, never from a copy an Agent edits (ADR 0002). Put its `bin` folder on your PATH:

```bash
git clone https://github.com/doleksy/podman4ai.git ~/podman4ai
echo 'export PATH="$HOME/podman4ai/bin:$PATH"' >> ~/.bashrc
```

### One-time setup (needs admin)

1. Enable the Hyper-V Windows feature.
2. In an admin PowerShell, join "Hyper-V Administrators": `Add-LocalGroupMember -SID S-1-5-32-578 -Member $env:USERNAME`
3. Sign out of Windows and back in. Check with `whoami /groups | findstr /i hyper-v`.
4. Open Git Bash with **Run as administrator** and run `p4a machine create`.

Step 4 needs admin because the first time Podman creates a Hyper-V machine, it relaunches itself as administrator. That relaunched copy ignores the settings that keep Windows drives out of the Sandbox machine. From an admin shell no relaunch happens. If you run it from a normal shell, `p4a` notices the shared drives, removes the machine and tells you to rerun it as administrator.

Everything else works from a normal Git Bash.

### Commands

```
p4a machine create   create the Sandbox machine (Hyper-V, 12 GB, 6 CPUs, 200 GB, no Windows drives)
p4a machine start    start it (stop any other running Podman machine first)
p4a machine stop     stop it
p4a machine status   show whether it exists and is running
p4a podman <args>    run any podman command against the Sandbox machine
```

`p4a` selects the Hyper-V provider and the Sandbox machine for its own Podman calls only. Plain `podman` in other shells keeps using its default machine.

## Running the unit tests

```bash
test/run.sh
```

The tests need Bash and Node, never a real Podman. They run real `p4a` commands against a stand-in `podman` (`test/fake/`) that records each call, with all Host settings in a temporary folder. `test/run.sh` uses `bats` from PATH, or fetches a pinned version with `npx`. Pass `.bats` files to run just those, e.g. `test/run.sh test/machine.bats`.
