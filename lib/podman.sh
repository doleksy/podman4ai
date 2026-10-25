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

# Print a Host file path in the form podman.exe understands. Under Git Bash
# that's C:/... (path conversion is off); elsewhere the path is unchanged.
p4a_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Print a path podman.exe reported (C:\...) in the form Bash understands.
p4a_unix_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else echo "$1"; fi
}
