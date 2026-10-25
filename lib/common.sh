# shellcheck shell=bash
# Shared helpers for p4a: messages and errors.

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
