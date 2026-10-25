# Prototype: Agent token in a proxied container

Evidence for #3, gathered on 2026-10-25. Scripts: [prototypes/agent-token/](../../prototypes/agent-token/).

**Result: _pending_.**

## Setup

- Windows 10 Pro 19045, Podman 6.1.4, WSL machine `podman-machine-default`.
- Claude Code 2.1.310 (native installer), with `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY` and `DISABLE_ERROR_REPORTING` set to 1.
- Internal network with `--internal --disable-dns`. tinyproxy 1.11.2 is the only container on both that network and the default network.
- The token is a Podman secret mounted at `/run/secrets/agent-token` (uid 1000, mode 0400). The entrypoint exports it as `CLAUDE_CODE_OAUTH_TOKEN`.

## 1. Does `claude -p` sign in from the token file alone?

**Yes.** With the open proxy, `claude -p "say hello"` replied `Hello! How can I help you today?`. The token came only from the mounted secret file. A short interactive session worked too.

## 2. Which domains are contacted?

Open proxy, during `claude -p` and a short interactive session:

| Requests | Domain | When |
|---|---|---|
| 21 | `api.anthropic.com` | `claude -p` and the interactive session |
| 1 | `platform.claude.com` | Interactive session start-up |
| 1 | `raw.githubusercontent.com` | Interactive session start-up |
| 2 | `downloads.claude.ai` | Interactive session, about 10 s in |

`claude -p` contacted only `api.anthropic.com`. The other three domains were contacted only by the interactive session, even with the self-updater, telemetry and error reporting off. Section 3 tests whether the session still works without them.

## 3. Is `api.anthropic.com` alone enough?

Strict proxy (only `api.anthropic.com` allowed): _pending_

## 4. Isolation and token exposure

| Check | Result |
|---|---|
| No direct route out | |
| No outside DNS | |
| Strict proxy refuses other domains | |
| Token not in `podman inspect` | |
| Token not in image history | |
| Token not in shell history | |

## 5. Token lifetime and regeneration

_pending: lifetime shown by `claude setup-token`, how to regenerate it, and how to replace the Podman secret._

## Found while building the prototype

- **An internal network's DNS answers "no such name" for outside names**, including for a container that is also on the default network. The proxy couldn't resolve `api.anthropic.com` until the internal network was created with `--disable-dns`. The proxy now resolves through the default network, and the Sandbox reaches it at a fixed IP through an `--add-host` entry. As a result the Sandbox has no DNS server at all (spec story 41), and lookups simply fail.
- **Git Bash rewrites `/run/...` arguments into Windows paths** before they reach `podman.exe`. The scripts set `MSYS_NO_PATHCONV=1` and pass `cygpath -m` paths where Podman needs a Windows path, such as a build folder. The Launcher (a Bash script) needs the same handling.
- tinyproxy logs a `CONNECT` request before it applies its filter, so refused domains appear in both the request lines and the "refused" lines of the log.
- Dry run with a fake token: Claude contacted only `api.anthropic.com` and failed with `401 Invalid bearer token`. The token file, the proxy route and the isolation checks all work, so only the real sign-in is left to test.
