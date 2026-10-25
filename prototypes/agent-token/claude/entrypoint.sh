#!/bin/sh
# Hand the Agent token from the mounted secret file to Claude Code. The token
# exists only in this process's environment, never in the container's
# definition, so `podman inspect` can't show it.
set -eu
secret=/run/secrets/agent-token
if [ -r "$secret" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat "$secret")"
  export CLAUDE_CODE_OAUTH_TOKEN
fi
exec "$@"
