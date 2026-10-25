# Prototype: Agent token in a proxied container (#3)

Throwaway. Checks that Claude Code signs in with only the Agent token from a mounted secret file, while its only route out is a logging HTTPS proxy. Runs on the existing WSL Podman machine (`podman-machine-default`), not the Sandbox machine. Write up the results in [docs/prototypes/agent-token.md](../../docs/prototypes/agent-token.md).

## What it sets up

- `p4a-proto-int`: an internal Podman network with no route out and no DNS server.
- `p4a-proto-proxy`: tinyproxy, on that network at `10.89.100.2` and on the default network. It logs every request. `open` mode allows everything; `strict` mode allows only `api.anthropic.com`.
- `p4a-proto-claude`: Debian with Claude Code (native installer). The self-updater, telemetry and error reporting are off. It is non-root, drops all capabilities and sets no-new-privileges. Its entrypoint reads `/run/secrets/agent-token` into `CLAUDE_CODE_OAUTH_TOKEN`.

## Run it (Git Bash)

1. Start the WSL machine if it isn't running: `podman machine start podman-machine-default`.
2. Create the token on the Host: `claude setup-token`. Sign in in the browser and copy the token it prints.
3. Store it: `./set-token.sh`. Paste at the hidden prompt. This replaces any existing `agent-token` secret.
4. Run everything: `./run.sh all`. It builds both images, then:
   - **open** proxy: `claude -p "say hello"`, isolation checks, then a short interactive session (try a prompt or two, then `/exit`), then the domain list.
   - **strict** proxy: `claude -p "say hello"` and the checks again, then the domain list.
5. Results are written to `.scratch/agent-token/` at the repo root (gitignored): `hello-*.txt`, `domains-*.txt` and the raw `proxy-*.log`. Check the logs before posting anything. They contain domains and timestamps but should never contain the token.

Each step can also be run on its own: `./run.sh build | up open|strict | hello | session | checks | domains | down`.

If the interactive session misbehaves in mintty, run it from Windows Terminal, or prefix it with `winpty`.

## Clean up

```bash
./run.sh down
podman rmi localhost/p4a-proto-claude localhost/p4a-proto-proxy
podman secret rm agent-token   # only once #3 is done
```
