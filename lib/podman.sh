# shellcheck shell=bash
# The one place p4a calls Podman.
#
# Every call selects the Sandbox machine's provider (ADR 0004) for this
# process only, so plain `podman` in other shells keeps its own default, and
# turns off Git Bash path conversion so arguments like /workspace reach
# Podman unchanged.

P4A_MACHINE=podman4ai
P4A_PROVIDER=hyperv

p4a_podman() {
  command -v podman >/dev/null 2>&1 \
    || p4a_die "podman not found on PATH" "install Podman for Windows (https://podman.io), then open a new Git Bash"
  MSYS_NO_PATHCONV=1 CONTAINERS_MACHINE_PROVIDER=$P4A_PROVIDER command podman "$@"
}

# Run a podman command inside the Sandbox machine (images, containers,
# networks), as opposed to `podman machine` commands about it.
p4a_sandbox_podman() {
  p4a_podman --connection "$P4A_MACHINE" "$@"
}

# p4a_sandbox_podman_on_terminal PODMAN_ARGUMENT...
# Like p4a_sandbox_podman, for a command that draws on this terminal (a
# shell, tmux). It runs podman inside the Sandbox machine over Git Bash's
# own ssh, with the address, user and key Podman uses. podman.exe is a
# native Windows program, so Git Bash would run it through Windows' ConPTY,
# which redraws the screen from its own copy and garbles full-screen
# programs such as Claude Code in tmux. ssh is a Git Bash program and
# doesn't go through ConPTY. Returns the command's exit code (ssh's own
# failures are 255).
p4a_sandbox_podman_on_terminal() {
  local info port identity user
  info="$(p4a_podman machine inspect \
    --format '{{.SSHConfig.Port}}|{{.SSHConfig.IdentityPath}}|{{.SSHConfig.RemoteUsername}}' "$P4A_MACHINE")" \
    || p4a_die "couldn't read how to reach the Sandbox machine over ssh" \
      "check it with 'podman machine inspect $P4A_MACHINE'"
  IFS='|' read -r port identity user <<< "${info%$'\r'}"
  [[ -n $port && -n $identity && -n $user ]] \
    || p4a_die "podman machine inspect didn't say how to reach the Sandbox machine over ssh (it said: $info)" \
      "check it with 'podman machine inspect $P4A_MACHINE'"
  command -v ssh >/dev/null 2>&1 \
    || p4a_die "ssh not found on PATH" "run p4a from Git Bash, which comes with ssh"
  # ssh hands the remote shell (bash) one string, so quote each argument.
  local remote
  printf -v remote '%q ' podman "$@"
  local status=0
  ssh -q -t -p "$port" -i "$(p4a_unix_path "$identity")" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$user@127.0.0.1" "$remote" || status=$?
  return "$status"
}

# Print a Host file path in the form podman.exe understands. Under Git Bash
# that's C:/... (path conversion is off); elsewhere the path is unchanged.
p4a_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Print a path podman.exe reported (C:\...) in the form Bash understands.
p4a_unix_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else echo "$1"; fi
}
