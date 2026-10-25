#!/usr/bin/env bash
# Drives the #3 prototype: Claude Code in a container whose only way out is
# a logging HTTPS proxy, signed in with the Agent token from a secret file.
#
#   ./run.sh all       build, test with an open proxy, then with only
#                      api.anthropic.com allowed; writes results to .scratch/
#   ./run.sh open      just the open-proxy half of `all` (no build)
#   ./run.sh strict    just the strict-proxy half of `all` (no build)
#   ./run.sh build     build both images
#   ./run.sh up MODE   (re)start the network and proxy; MODE is open or strict
#   ./run.sh hello     claude -p "say hello"
#   ./run.sh session   short interactive Claude session (exit with /exit)
#   ./run.sh checks    isolation and token-exposure checks
#   ./run.sh domains   list domains the proxy saw since the last `up`
#   ./run.sh down      remove the containers and network
set -euo pipefail
export MSYS_NO_PATHCONV=1  # stop Git Bash rewriting /run/... paths

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/.scratch/agent-token"
mkdir -p "$out"

secret="${SECRET_NAME:-agent-token}"
net=p4a-proto-int
proxy=p4a-proto-proxy
proxy_img=localhost/p4a-proto-proxy
claude_img=localhost/p4a-proto-claude
# Fixed address, because the internal network has no DNS server at all.
proxy_ip=10.89.100.2
subnet=10.89.100.0/24
proxy_url="http://$proxy:8888"

checks_file=""
report() { echo "$*"; [[ -z "$checks_file" ]] || echo "$*" >> "$checks_file"; }
pass() { report "PASS  $*"; }
fail() { report "FAIL  $*"; failures=$((failures + 1)); }
failures=0

claude_run() {
  podman run --rm "$@"
}

# Flags shared by every Claude container: internal network only, the token
# as a file, proxy settings, and basic hardening.
claude_flags=(
  --network "$net"
  --add-host "$proxy:$proxy_ip"
  --secret "$secret,target=agent-token,uid=1000,mode=0400"
  --cap-drop=all
  --security-opt no-new-privileges
  -e "HTTPS_PROXY=$proxy_url" -e "https_proxy=$proxy_url"
  -e "HTTP_PROXY=$proxy_url"  -e "http_proxy=$proxy_url"
)

cmd_build() {
  # podman.exe needs a Windows path for the build context.
  local ctx="$here"
  command -v cygpath >/dev/null && ctx="$(cygpath -m "$here")"
  podman build -t "$proxy_img" "$ctx/proxy"
  podman build -t "$claude_img" "$ctx/claude"
}

cmd_up() {
  local mode="${1:-open}"
  case "$mode" in open|strict) ;; *) echo "mode must be open or strict" >&2; exit 2 ;; esac
  podman rm -f "$proxy" >/dev/null 2>&1 || true
  # Internal: no route out. No DNS: a Sandbox can't resolve names or leak
  # data through lookups. The proxy resolves via the default network's DNS.
  podman network exists "$net" ||
    podman network create --internal --disable-dns --subnet "$subnet" "$net" >/dev/null
  # The proxy is the only container on both the internal network and the
  # default (internet-facing) one.
  podman run -d --name "$proxy" --network podman --network "$net:ip=$proxy_ip" \
    "$proxy_img" tinyproxy -d -c "/etc/tinyproxy/$mode.conf" >/dev/null
  echo "$mode" > "$out/mode"
  sleep 2
  echo "Proxy up in $mode mode."
}

cmd_hello() {
  podman secret exists "$secret" || { echo "No Podman secret '$secret'; run ./set-token.sh first." >&2; exit 1; }
  local mode; mode="$(cat "$out/mode")"
  echo "--- claude -p \"say hello\" ($mode proxy)"
  if claude_run "${claude_flags[@]}" "$claude_img" claude -p "say hello" 2>&1 | tee "$out/hello-$mode.txt"; then
    pass "claude -p succeeded ($mode proxy)"
  else
    fail "claude -p failed ($mode proxy); see $out/hello-$mode.txt"
  fi
}

cmd_session() {
  podman secret exists "$secret" || { echo "No Podman secret '$secret'; run ./set-token.sh first." >&2; exit 1; }
  podman run --rm -it "${claude_flags[@]}" "$claude_img" claude
}

cmd_checks() {
  local mode; mode="$(cat "$out/mode")"
  echo "--- checks ($mode proxy)"
  checks_file="$out/checks-$mode.txt"
  : > "$checks_file"

  if claude_run "${claude_flags[@]}" "$claude_img" \
      curl -sS --max-time 10 --noproxy '*' -o /dev/null https://example.com 2>/dev/null; then
    fail "direct connection to example.com worked (should have no route)"
  else
    pass "no direct route out"
  fi

  if claude_run "${claude_flags[@]}" "$claude_img" timeout 10 getent hosts example.com >/dev/null 2>&1; then
    fail "outside DNS lookup worked"
  else
    pass "no outside DNS"
  fi

  if claude_run "${claude_flags[@]}" "$claude_img" \
      curl -sS --max-time 15 -o /dev/null https://api.anthropic.com 2>/dev/null; then
    pass "api.anthropic.com reachable through the proxy"
  else
    fail "api.anthropic.com not reachable through the proxy"
  fi

  if [[ "$mode" == strict ]]; then
    if claude_run "${claude_flags[@]}" "$claude_img" \
        curl -sS --max-time 15 -o /dev/null https://example.com 2>/dev/null; then
      fail "strict proxy let example.com through"
    else
      pass "strict proxy refuses example.com"
    fi
  fi

  # Token exposure: look for the token's prefix, never print the token.
  if podman secret exists "$secret"; then
    local probe=p4a-proto-probe
    podman rm -f "$probe" >/dev/null 2>&1 || true
    podman run -d --name "$probe" "${claude_flags[@]}" "$claude_img" sleep 60 >/dev/null
    if podman inspect "$probe" | grep -qE 'sk-ant|CLAUDE_CODE_OAUTH_TOKEN'; then
      fail "token or token variable visible in podman inspect"
    else
      pass "token not in podman inspect"
    fi
    if podman exec "$probe" sh -c 'test "$(stat -c %a /run/secrets/agent-token)" = 400' 2>/dev/null; then
      pass "secret file is mode 0400"
    else
      fail "secret file mode is not 0400"
    fi
    podman rm -f "$probe" >/dev/null
  fi
  if podman history --no-trunc "$claude_img" | grep -q 'sk-ant'; then
    fail "token found in image history"
  else
    pass "token not in image history"
  fi
  if grep -qs 'sk-ant' ~/.bash_history; then
    fail "token found in ~/.bash_history"
  else
    pass "token not in ~/.bash_history"
  fi
}

cmd_domains() {
  local mode; mode="$(cat "$out/mode")"
  podman logs "$proxy" > "$out/proxy-$mode.log" 2>&1
  {
    echo "# Requested through the proxy ($mode); request count, domain"
    grep -oE 'Request \(file descriptor [0-9]+\): [A-Z]+ [^ ]+' "$out/proxy-$mode.log" \
      | awk '{print $NF}' | sed -E 's#^[a-z]+://##; s#[:/].*$##' | sort | uniq -c | sort -rn || true
    echo "# Refused by the proxy ($mode)"
    grep -oE 'refused on filtered domain "[^"]+"' "$out/proxy-$mode.log" \
      | sed -E 's/.*"(.*)"/\1/' | sort | uniq -c | sort -rn || true  # none refused is fine
  } | tee "$out/domains-$mode.txt"
}

cmd_down() {
  podman rm -f "$proxy" p4a-proto-probe >/dev/null 2>&1 || true
  podman network rm "$net" >/dev/null 2>&1 || true
  echo "Removed proxy and network."
}

run_mode() {
  cmd_up "$1"
  cmd_hello
  cmd_checks
  echo "Now run a short interactive session; type a prompt or two, then /exit."
  read -rp "Press Enter to start it (or type 'skip'): " answer
  [[ "$answer" == skip ]] || cmd_session
  cmd_domains
}

finish() {
  cmd_down
  echo
  echo "Results are in $out (gitignored). Failures: $failures"
}

cmd_all()    { cmd_build; run_mode open; run_mode strict; finish; }
cmd_open()   { run_mode open; finish; }
cmd_strict() { run_mode strict; finish; }

case "${1:-}" in
  build|hello|session|checks|domains|down|all|open|strict) "cmd_$1" ;;
  up) cmd_up "${2:-open}" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
exit $(( failures > 0 ))
