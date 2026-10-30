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

After a Windows restart the Sandbox machine can be running while Podman's `gvproxy` helper isn't, so Podman in it doesn't answer. `p4a machine status` and every command that needs the Sandbox machine say so. Fix it with `p4a machine stop`, then `p4a machine start`.

### Commands

```
p4a machine create   create the Sandbox machine (Hyper-V, 12 GB, 6 CPUs, 200 GB, no Windows drives)
p4a machine start    start it (stop any other running Podman machine first)
p4a machine stop     stop it
p4a machine status   show whether it exists and is running
p4a image build      build the Egress proxy image, then the Base image through it
p4a secret set agent-token
                     store the Agent token (from 'claude setup-token'), from a hidden prompt
p4a secret set repo-token <project>
                     store a project's Repo token, from a hidden prompt
p4a new <owner/repo> create a project from a GitHub repo, and start its Sandbox
p4a start <project>  start a project's Egress proxy and Sandbox, then run the self-check
p4a stop <project>   stop a project's Sandbox and Egress proxy
p4a shell <project>  open a shell in a project's Sandbox, in its source folder
p4a shell <project> -- <command>...
                     run one command there and return its exit code
p4a allow <project> <domain>
                     let a project's Sandbox reach a domain (or *.domain), without a restart
p4a disallow <project> <domain>
                     take back a domain allowed with p4a allow
p4a blocked <project>
                     list the domains a project's Egress proxy refused, most frequent first
p4a podman <args>    run any podman command against the Sandbox machine
```

### Secrets

Sandboxes sign in to Claude with the **Agent token** and to GitHub with their project's **Repo token**. Both are Podman secrets in the Sandbox machine. `p4a` reads each one from a hidden prompt and passes it to Podman on stdin, so it never appears on a command line, in shell history, in an image or in `podman inspect`.

1. On the Host, run `claude setup-token`, then `p4a secret set agent-token` and paste the token. It lasts a year.
2. For each project that should push (or whose repo is private), create a fine-grained token on GitHub for that one repository, with read and write access to contents and pull requests. Store it with `p4a secret set repo-token <project>`, before `p4a new` if the repo is private.

A project with no Repo token works with a public repo, but can't push: git says how to set one. A Sandbox gets copies of its tokens when it's created, so a token stored, changed or removed since then reaches it at its next `p4a stop`, then `p4a start`: `p4a start` notices and recreates the Sandbox. Its source and Claude config are kept, in their volumes; anything else changed inside the container is lost. A running Sandbox is never recreated.

Projects created before secrets existed get their tokens the same way, at their next stop and start, once the images are rebuilt.

Each Sandbox mounts the Agent token at `/run/secrets/agent-token` and only its own project's Repo token, if it has one, at `/run/secrets/repo-token`, readable only by `agent`. `p4a shell` runs every command through `p4a-session`, which hands the Agent token to Claude Code. git uses a credential helper that reads the Repo token for `https://github.com`. Commits carry your name and email, from the Host's `git config --global user.name` and `user.email`. Claude Code adds a Co-Authored-By line to the commits it makes.

### Projects

`p4a new octo/hello-world` creates the project `hello-world` (the repository's name in lower case). It needs the Sandbox machine running, both images built (rebuild any images made before secrets existed: the Sandbox needs `p4a-session`), the Agent token stored, and your git name and email set on the Host. The project has:

- a Project volume, `podman4ai-hello-world-source`, mounted at `/workspace`, with the repo cloned over HTTPS to `/workspace/hello-world`, using the project's Repo token if it has one
- a Claude config volume, `podman4ai-hello-world-claude`, mounted at `/home/agent/.claude`
- an internal network, `podman4ai-hello-world`, with no route out and no DNS, and its own subnet
- an Egress proxy, `podman4ai-hello-world-proxy`, given the project's Allowlist (see [Allowlists](#allowlists))
- the Sandbox, `podman4ai-hello-world`, on that network only. It runs as the non-root user `agent` with all capabilities dropped, no-new-privileges, Podman's default seccomp and SELinux, no Podman socket and no Host paths, and is limited to 4 GB memory, 4 CPUs and 4096 processes.

Every start runs a self-check from inside the Sandbox: `github.com` must be reachable through the Egress proxy and `example.com` must not be. If either check fails, `p4a` stops the Sandbox and its proxy and says why.

If `p4a new` fails partway, it removes what it created, so you can run it again. It never reuses or removes a volume, network or container that already had the project's name.

A project's Host settings are in `%APPDATA%\podman4ai\projects\` (or `$P4A_CONFIG_DIR/projects`): `<project>.conf`, and its Allowlist additions in `<project>.allowlist`. They're outside every repo and every Sandbox, so no Agent can change them.

### Allowlists

A project's Sandbox may reach the domains on the default Allowlist ([`share/default-allowlist`](share/default-allowlist)), which every project shares, plus the project's own additions. Only you can change those, from the Host:

```
p4a blocked hello-world             # the domains it was refused, most frequent first
p4a allow hello-world example.org   # allow one (or *.example.org for its subdomains)
p4a disallow hello-world example.org
```

`p4a allow` and `p4a disallow` save the change in `hello-world.allowlist`. If the project is running, they also write its effective Allowlist into its Egress proxy, which applies it within a few seconds without restarting anything. A stopped project gets it at `p4a start`. One project's additions never reach another project's proxy. To change the default for every project, change `share/default-allowlist` in podman4ai. When the proxy refuses a domain, its message names the domain and the `p4a allow` command, so an Agent can tell you what to allow.

Egress proxies created before Allowlist additions existed can't apply them. Rebuild the images with `p4a image build`, then stop and start each project: `p4a start` recreates an old proxy, losing only its log.

### Images

`p4a image build` needs the Sandbox machine running. It builds two images:

- `localhost/podman4ai-proxy`, the Egress proxy (`images/proxy/`). Its own build has no network.
- `localhost/podman4ai-base`, the Base image (`images/base/`): Debian bookworm with Claude Code, Node (the latest LTS), Python with uv, Bun, gh, git with git-delta, ripgrep, jq, fzf, less, nano and tmux (mouse on, the project's name in the status bar), a non-root user `agent`, and no sudo, zsh or firewall tooling. It's rebuilt from scratch each time, so it gets the latest OS patches and the latest release of each tool. Claude Code's self-updater, telemetry and error reporting are off; it updates when the image is rebuilt.

`agent` installs its own tools without root, into its home: `npm install -g` (into `~/.npm-global`), `uv tool install`, `bun add -g` and `pip install --user`. They're on PATH, and survive `p4a stop` and `p4a start`. They're lost when the Sandbox is recreated, which `p4a start` does after a token changes, and they aren't in a Sandbox created from a rebuilt image.

After the build, `p4a` labels the Base image with when it was built and which Claude Code it has, and prints both:

```bash
p4a podman image inspect --format '{{json .Labels}}' localhost/podman4ai-base
# {"org.opencontainers.image.created":"2026-10-29T22:51:07Z","podman4ai.claude-code-version":"2.1.312",...}
```

The Base image build has no open internet. Its only way out is an Egress proxy that allows just the domains in [`share/build-allowlist`](share/build-allowlist) (ADR 0003, ADR 0005). Afterwards `p4a` lists the domains the proxy allowed and refused. The full log stays in the stopped proxy container until the next build: `p4a podman logs podman4ai-build-proxy`. If a build fails because a domain was refused, and that domain should be allowed, add it to `share/build-allowlist`.

`p4a` selects the Hyper-V provider and the Sandbox machine for its own Podman calls only. Plain `podman` in other shells keeps using its default machine.

## Running the unit tests

```bash
test/run.sh
```

The tests need Bash and Node, never a real Podman. They run real `p4a` commands against a stand-in `podman` (`test/fake/`) that records each call, with all Host settings in a temporary folder. `test/run.sh` uses `bats` from PATH, or fetches a pinned version with `npx`. Pass `.bats` files to run just those, e.g. `test/run.sh test/machine.bats`.

The Egress proxy tests (`test/proxy.bats`) run the real proxy under Node on the Host, against a stand-in web server on localhost.

### Host-only checks

These run against the real Sandbox machine, which must be running, and take several minutes. Run them before merging any change to the Launcher, images or Egress proxy:

```bash
test/host/isolation.sh     # the isolation suite: one PASS/FAIL line per security property
test/host/image-build.sh   # bad build step refused, build log clean, no sudo, non-root
test/host/secrets.sh       # each Sandbox sees only its own Repo token, no token in podman inspect
test/host/base-image.sh    # every Base image tool runs as agent, user installs survive a restart, labels
```

`test/host/isolation.sh` needs both images built. It creates two throwaway projects, `spoon-knife` (from `octocat/Spoon-Knife`) and `test-repo1` (from `octocat/test-repo1`), and runs each check inside a Sandbox with `p4a shell <project> -- <command>`. The checks cover: non-allowlisted domains refused and logged, allowlisted domains working through the proxy, `p4a blocked` listing a refused domain, `p4a allow` opening a domain within seconds for its own project only and `p4a disallow` closing it again, no outside DNS, no Host paths, non-root user with no capabilities, no sudo and no-new-privileges, no Podman socket, no route from one Sandbox to another or to its proxy, and the process and memory limits. Afterwards it removes both projects, their volumes and their network, even after a failure or Ctrl-C. It refuses to start if anything with those names already exists. To use other public repos, set `P4A_ISOLATION_REPO_A` and `P4A_ISOLATION_REPO_B` to `owner/repo`. It refuses to run inside a Sandbox.
