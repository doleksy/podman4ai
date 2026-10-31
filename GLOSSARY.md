# podman4ai

A secure environment on a Windows workstation where all AI agent work happens inside Podman containers, isolated from the host and from other projects.

## Language

### Places

**Host**:
The Windows workstation itself, including its filesystem, credentials and other repos. The thing being protected.
_Avoid_: local machine, desktop

**Sandbox machine**:
The dedicated Podman machine (a Hyper-V VM with its own kernel) that runs all Sandboxes, cut off from the Host's drives and programs. Separate from any general-purpose Podman machine.
_Avoid_: VM, podman machine, WSL distro

**Sandbox**:
A running container dedicated to exactly one project, where agent sessions for that project happen. It can see only that project.
_Avoid_: devcontainer, box, VM, environment

**Allowlist**:
The set of network destinations a Sandbox may reach; everything else is blocked. A shared default plus per-project additions.
_Avoid_: whitelist, firewall rules

**Build Allowlist**:
The Allowlist for building the Base image (Debian mirrors, Claude Code's installer, and where the Base image's other tools are released), kept in podman4ai's own configuration and separate from any Sandbox's Allowlist.
_Avoid_: build whitelist

**Launcher**:
podman4ai's Host-side command that creates, starts, enters and removes Sandboxes. The sole authority on how a Sandbox is configured.
_Avoid_: CLI, wrapper, script, devcontainer

**Egress proxy**:
The container that is a Sandbox's only route to the internet, permitting connections to Allowlist domains and refusing the rest.
_Avoid_: firewall, gateway, proxy server

### Images

**Base image**:
The single shared image every Sandbox starts from, holding the agent tooling and common dev tools.
_Avoid_: default image, master image

**Project image**:
An optional image built on top of the Base image for one project that needs extra toolchains.
_Avoid_: custom image, child image

**Project volume**:
The persistent storage holding one project's source, attached only to that project's Sandbox and outliving any individual Sandbox.
_Avoid_: workspace, mount, checkout

**Claude config volume**:
The persistent storage holding one project's Agent settings, hooks and memory, attached only to that project's Sandbox, so an Agent can't plant anything that affects another project.
_Avoid_: claude dir, home volume

**Claude baseline**:
The Claude Code setup every Sandbox starts with: user settings, permissions, the plugin list and any user-level CLAUDE.md. It's versioned in podman4ai, and its plugins are built into the Base image. It's copied into a Claude config volume without overwriting anything already there.
_Avoid_: dotfiles, default config, Windows settings

### Work

**Agent**:
An AI coding tool (initially Claude Code) running inside a Sandbox.
_Avoid_: bot, assistant, AI

**Agent token**:
The single long-lived credential that lets an Agent use the user's Claude subscription. The only secret shared by all Sandboxes.
_Avoid_: API key, login, auth

**Repo token**:
A GitHub credential scoped to exactly one repository, given only to that project's Sandbox.
_Avoid_: PAT, GitHub token, git credentials

**Bootstrapping**:
The period before podman4ai's first working version, the only time an Agent may run directly on the Host.
_Avoid_: setup phase
