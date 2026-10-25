#!/usr/bin/env bash
# Store the Agent token as a Podman secret, read from a hidden prompt so it
# never lands in a command line or shell history. Run `claude setup-token`
# on the Host first and paste its output here.
set -euo pipefail
export MSYS_NO_PATHCONV=1

name="${SECRET_NAME:-agent-token}"

read -rsp "Paste the Agent token (input hidden): " token
echo
if [[ -z "$token" ]]; then
  echo "No token entered; nothing stored." >&2
  exit 1
fi

podman secret rm "$name" >/dev/null 2>&1 || true
printf %s "$token" | podman secret create "$name" - >/dev/null
unset token
echo "Stored Podman secret '$name' (value not shown)."
