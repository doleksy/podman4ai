# Shared setup for the p4a unit tests.
#
# Each test runs real `p4a` commands with a stand-in podman first on PATH and
# every Host location (settings, Podman's temp folder) inside a fresh
# temporary folder, so no test needs or touches a real Podman or Host.

P4A_REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  export FAKE_PODMAN_DIR="$BATS_TEST_TMPDIR/podman"
  mkdir -p "$FAKE_PODMAN_DIR/rules"
  : > "$FAKE_PODMAN_DIR/calls.jsonl"

  export HOME="$BATS_TEST_TMPDIR/home"
  export P4A_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$HOME" "$P4A_CONFIG_DIR"

  # p4a must set these itself; don't let the test runner's shell hide a bug.
  unset MSYS_NO_PATHCONV CONTAINERS_MACHINE_PROVIDER CONTAINERS_CONF_OVERRIDE

  PATH="$P4A_REPO/test/fake:$P4A_REPO/bin:$PATH"

  # What `podman machine inspect` reports for the Sandbox machine: where its
  # config and API socket live. By default, its config shares no drives.
  SANDBOX_CONFIG_DIR="$BATS_TEST_TMPDIR/machine-config"
  SANDBOX_SOCKET="$BATS_TEST_TMPDIR/podman-temp/podman4ai-api.sock"
  mkdir -p "$SANDBOX_CONFIG_DIR" "$(dirname "$SANDBOX_SOCKET")"
  fake_podman "machine inspect --format {{.ConfigDir.Path}} podman4ai" --stdout "$SANDBOX_CONFIG_DIR"
  fake_podman "machine inspect --format {{.ConnectionInfo.PodmanSocket.Path}} podman4ai" --stdout "$SANDBOX_SOCKET"
  sandbox_machine_mounts '[]'
  # Like Podman, removing the machine deletes its config.
  fake_podman "machine rm" --remove "$SANDBOX_CONFIG_DIR/podman4ai.json"

  export FAKE_POWERSHELL_DIR="$BATS_TEST_TMPDIR/powershell"
  mkdir -p "$FAKE_POWERSHELL_DIR/rules"
  : > "$FAKE_POWERSHELL_DIR/calls"
  # By default the Sandbox machine's VM has Hyper-V dynamic memory off.
  dynamic_memory False
}

# fake_powershell TEXT [--stdout TEXT] [--stderr TEXT] [--exit N]
# PowerShell calls whose arguments contain TEXT get this reply. A later rule
# beats an earlier one.
fake_powershell() {
  local match=$1; shift
  local n
  n=$(( $(find "$FAKE_POWERSHELL_DIR/rules" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
  local rule="$FAKE_POWERSHELL_DIR/rules/$n"
  mkdir -p "$rule"
  printf '%s' "$match" > "$rule/match"
  while (( $# )); do
    case $1 in
      --stdout) printf '%s\r\n' "$2" > "$rule/stdout" ;;
      --stderr) printf '%s\r\n' "$2" > "$rule/stderr" ;;
      --exit) printf '%s' "$2" > "$rule/exit" ;;
      *) echo "fake_powershell: unknown option $1" >&2; return 1 ;;
    esac
    shift 2
  done
}

# dynamic_memory True|False
# Sets what Hyper-V reports as the Sandbox machine VM's dynamic-memory
# setting. Like PowerShell, the reply ends in CRLF.
dynamic_memory() {
  fake_powershell "Get-VMMemory" --stdout "$1"
}

# Print one line per recorded PowerShell call: its arguments joined by spaces.
powershell_calls() {
  cat "$FAKE_POWERSHELL_DIR/calls"
}

# Print the recorded PowerShell calls that contain TEXT.
powershell_calls_with() {
  grep -F -- "$1" "$FAKE_POWERSHELL_DIR/calls" || true
}

# sandbox_machine_mounts JSON
# Sets the Mounts list in the Sandbox machine's Podman config file.
sandbox_machine_mounts() {
  printf '{"Created":"2026-10-25T15:42:10Z","Mounts":%s,"Name":"podman4ai"}' "$1" \
    > "$SANDBOX_CONFIG_DIR/podman4ai.json"
}

# A Mounts list sharing Windows drives, as Podman writes it by default.
# shellcheck disable=SC2034 # read by test/machine.bats
WINDOWS_DRIVE_MOUNTS='[{"OriginalInput":"C:\\Users\\me:/Users/me","ReadOnly":false,"Source":"C:\\Users\\me","Tag":"vol0","Target":"/Users/me","Type":"9p"},{"OriginalInput":"C:\\:/mnt/c","ReadOnly":false,"Source":"C:\\","Tag":"vol1","Target":"/mnt/c","Type":"9p"}]'

# fake_podman PREFIX [--stdout TEXT] [--stderr TEXT] [--exit N] [--remove FILE]
# Calls whose arguments start with the words in PREFIX get this reply, and
# delete FILE if given. A later rule beats an earlier one.
fake_podman() {
  local prefix=$1; shift
  local n
  n=$(( $(find "$FAKE_PODMAN_DIR/rules" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
  local rule="$FAKE_PODMAN_DIR/rules/$n"
  mkdir -p "$rule"
  printf '%s' "$prefix" > "$rule/prefix"
  while (( $# )); do
    case $1 in
      --stdout) printf '%s\n' "$2" > "$rule/stdout" ;;
      --stderr) printf '%s\n' "$2" > "$rule/stderr" ;;
      --exit) printf '%s' "$2" > "$rule/exit" ;;
      --remove) _native_path "$2" > "$rule/remove" ;;
      *) echo "fake_podman: unknown option $1" >&2; return 1 ;;
    esac
    shift 2
  done
}

# A path in the form node (a Windows program under Git Bash) understands.
_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# machines "NAME PROVIDER STATE" ...
# Sets what `podman machine list` reports. STATE is running, starting or
# stopped. With no arguments, no machines exist.
machines() {
  local lines=() name provider state
  for m in "$@"; do
    read -r name provider state <<< "$m"
    lines+=("$name|$provider|$([[ $state == running ]] && echo true || echo false)|$([[ $state == starting ]] && echo true || echo false)")
  done
  if (( ${#lines[@]} )); then
    fake_podman "machine list" --stdout "$(printf '%s\n' "${lines[@]}")"
  else
    fake_podman "machine list" --stdout ""
  fi
}

# Print one line per recorded podman call: its arguments joined by spaces.
podman_calls() {
  _calls 'c.args.join(" ")'
}

# Print the recorded podman calls whose arguments start with PREFIX.
podman_calls_starting() {
  podman_calls | grep "^$1" || true
}

# Print one line per recorded podman call: the value of an environment
# variable podman saw, or <unset>.
podman_call_env() {
  _calls "c.env[\"$1\"] ?? \"<unset>\""
}

# Print the argument list of call number N (1-based) as a JSON array.
podman_call_args_json() {
  _calls 'JSON.stringify(c.args)' | sed -n "${1}p"
}

# Print the CONTAINERS_CONF_OVERRIDE file contents seen by the call whose
# arguments start with PREFIX.
podman_call_conf() {
  _calls "c.args.join(\" \").startsWith(\"$1\") ? (c.conf ?? \"<none>\") : null"
}

_calls() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    for (const line of lines) {
      const c = JSON.parse(line);
      const out = ('"$1"');
      if (out !== null) console.log(out);
    }' "$FAKE_PODMAN_DIR/calls.jsonl"
}

# The Sandbox machine lists as running but nothing answers Podman's API, as
# after a Windows restart when Podman's gvproxy helper isn't running.
podman_not_answering() {
  fake_podman "--connection podman4ai info" --exit 125 \
    --stderr "Error: unable to connect to Podman socket: failed to connect: dial tcp 127.0.0.1:54918: connectex: No connection could be made because the target machine actively refused it."
}
