# Prototype: Agent token in a proxied container

Evidence for #3, gathered on 2026-10-25. Scripts: [prototypes/agent-token/](../../prototypes/agent-token/).

**Result: confirmed.** Claude Code signs in using only the Agent token from a mounted secret file, through an Egress proxy that allows only `api.anthropic.com`. This holds for `claude -p` and for interactive sessions, provided the image's `~/.claude.json` marks first-run setup as done (see [section 3](#3-is-apianthropiccom-alone-enough)).

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

**Yes, provided `~/.claude.json` already marks first-run setup as done.** The Base image bakes that file in anyway (spec story 14).

Strict proxy (only `api.anthropic.com` allowed):

- **`claude -p`: works.** It replied `Hello! How can I help you today?` with the real token.
- **Interactive session with a fresh `~/.claude.json`: fails** before the prompt appears:
  ```
  Unable to connect to Anthropic services
  Failed to connect to platform.claude.com: ERR_PROXY_TUNNEL
  ```
  The proxy refused `platform.claude.com` and `raw.githubusercontent.com`. With `platform.claude.com` allowed, the session gets to the first-run theme picker, so the connectivity check belongs to first-run setup.
- **Interactive session with `hasCompletedOnboarding: true` and the folder already trusted: starts.** It reaches the prompt without contacting `platform.claude.com`. Confirmed first with a fake token in a simulated terminal, then with the real token: the session answered a prompt while the proxy refused every domain except `api.anthropic.com`. The image now includes this file ([claude.json](../../prototypes/agent-token/claude/claude.json)).

Domains the started session still tries, all refused with no visible effect:

| Domain | With `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
|---|---|
| `downloads.claude.ai` | Still tried |
| `github.com` | Still tried (it's on the default Allowlist anyway) |
| `raw.githubusercontent.com` | No longer tried |

## 4. Isolation and token exposure

Same results with the open and strict proxies, using the real token:

| Check | Result |
|---|---|
| No direct route out | Pass |
| No outside DNS | Pass |
| Strict proxy refuses other domains | Pass (`example.com` refused) |
| Token not in `podman inspect` | Pass |
| Secret file mode 0400 | Pass |
| Token not in image history | Pass |
| Token not in shell history | Pass |
| Token not in proxy logs | Pass (no `sk-ant` in either log) |

## 5. Token lifetime and regeneration

- **Lifetime: 1 year** from creation. `claude setup-token` reports this when it creates the token. `claude setup-token --help` doesn't mention it.
- **Regenerate:** on the Host, run `claude setup-token` again and sign in in the browser. It's interactive, so the developer has to do it.
- **Replace the secret:** `./set-token.sh` here, later `p4a secret set agent-token`. Both read the token from a hidden prompt, then run `podman secret rm` and `podman secret create`. Podman mounts secrets when a container is created, so running Sandboxes keep the old value until they are recreated.
- **For the Launcher:** an expired token shows up as `401 Invalid bearer token` (seen with the fake token). The Launcher can't read the expiry date from the token, so it could record the creation date when the secret is stored and warn as the year runs out.

## Found while building the prototype

- **An internal network's DNS answers "no such name" for outside names**, including for a container that is also on the default network. The proxy couldn't resolve `api.anthropic.com` until the internal network was created with `--disable-dns`. The proxy now resolves through the default network, and the Sandbox reaches it at a fixed IP through an `--add-host` entry. As a result the Sandbox has no DNS server at all (spec story 41), and lookups simply fail.
- **Git Bash rewrites `/run/...` arguments into Windows paths** before they reach `podman.exe`. The scripts set `MSYS_NO_PATHCONV=1` and pass `cygpath -m` paths where Podman needs a Windows path, such as a build folder. The Launcher (a Bash script) needs the same handling.
- tinyproxy logs a `CONNECT` request before it applies its filter, so refused domains appear in both the request lines and the "refused" lines of the log.
- Dry run with a fake token: Claude contacted only `api.anthropic.com` and failed with `401 Invalid bearer token`. The token file, the proxy route and the isolation checks all work, so only the real sign-in is left to test.
- **Interactive tests in a simulated terminal:** `script -qc claude` hangs when Podman is also given `-t`. Run it without `-t`, and `script` supplies the terminal. This is useful for automated integration tests of an interactive session.
