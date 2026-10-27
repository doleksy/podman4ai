# shellcheck shell=bash
# Shared helpers for p4a: messages, errors and reading Allowlist files.

# p4a_die MESSAGE [FIX]
# Exit 1 with what went wrong and, when known, how to fix it.
p4a_die() {
  echo "p4a: $1" >&2
  [[ -z ${2:-} ]] || echo "  fix: $2" >&2
  exit 1
}

# p4a_usage_error MESSAGE HELP_COMMAND
# Exit 2 for a command line p4a doesn't understand.
p4a_usage_error() {
  echo "p4a: $1" >&2
  echo "  see: $2" >&2
  exit 2
}

p4a_note() {
  echo "p4a: $*" >&2
}

# p4a_read_allowlist FILE
# Print the domains in an Allowlist file, separated by spaces. The file has
# one domain per line; "#" starts a comment.
p4a_read_allowlist() {
  local line domains=()
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n $line ]] && domains+=("$line")
  done < "$1"
  echo "${domains[*]}"
}
