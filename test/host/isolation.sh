#!/usr/bin/env bash
# Host-only isolation suite (#7): proves each Sandbox security property
# against the real Sandbox machine. Run it on the Host before merging any
# change to the Launcher, images or Egress proxy. Needs the Sandbox machine
# running and both images built. Takes a few minutes.
#
#   test/host/isolation.sh
#
# It creates two throwaway projects, A and B, runs each check inside a
# Sandbox with `p4a shell <project> -- <command>`, prints one PASS or FAIL
# line per property, and removes both projects afterwards, even after a
# failure or Ctrl-C. It exits 0 only if every check passed and nothing was
# left behind.
#
# Add a check: write a function that runs something in a Sandbox, prints
# what went wrong and returns non-zero on failure, then call it with
# `check "<the property it protects>" <function>` in main.
set -uo pipefail

# Never inside a Sandbox (or any container): this suite drives the Sandbox
# machine from the Host, and must not be mistaken for a unit test.
if [[ -e /run/.containerenv || -e /.dockerenv ]]; then
  echo "isolation.sh: this is a Host-only suite and can't run inside a Sandbox or other container." >&2
  echo "  fix: run it from Git Bash on the Host, with the Sandbox machine running." >&2
  echo "  (inside a Sandbox, run the unit tests instead: test/run.sh)" >&2
  exit 2
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
self="$repo/test/host/$(basename "$0")"
p4a() { "$repo/bin/p4a" "$@"; }

# The throwaway projects: tiny public repos whose project names (the repo
# name in lower case) are unlikely to be real projects.
REPO_A=${P4A_ISOLATION_REPO_A:-octocat/Spoon-Knife}
REPO_B=${P4A_ISOLATION_REPO_B:-octocat/test-repo1}
A="$(basename "${REPO_A,,}")"
B="$(basename "${REPO_B,,}")"

# Where p4a keeps project settings (see README, "Projects").
projects_dir() {
  if [[ -n ${P4A_CONFIG_DIR:-} ]]; then
    echo "$P4A_CONFIG_DIR/projects"
  elif [[ -n ${APPDATA:-} ]]; then
    echo "$(cygpath -u "$APPDATA")/podman4ai/projects"
  else
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/podman4ai/projects"
  fi
}

# The Sandbox machine parts of PROJECT, as "kind:name" (see README).
project_parts() {
  echo "container:podman4ai-$1" "container:podman4ai-$1-proxy" "network:podman4ai-$1" \
    "volume:podman4ai-$1-source" "volume:podman4ai-$1-claude"
}

# Run COMMAND in PROJECT's Sandbox, with no input.
in_sandbox() {
  local project=$1
  shift
  p4a shell "$project" -- "$@" < /dev/null
}

# Run the Bash script on stdin in PROJECT's Sandbox, with ARGS.
script_in() {
  local project=$1
  shift
  p4a shell "$project" -- bash -s -- "$@"
}

# How many lines of PROJECT's Egress proxy log contain TEXT.
proxy_log_count() {
  local log
  log="$(p4a podman logs "podman4ai-$1-proxy" 2>&1)" \
    || { echo "couldn't read the Egress proxy's log: $log" >&2; return 1; }
  grep -cF -- "$2" <<< "$log" || true
}

# The port every Egress proxy listens on (see README, "Projects").
PROXY_PORT=8888

# The IP addresses of a container on all its networks.
addresses_of() {
  p4a podman container inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1"
}

failures=0
# check PROPERTY FUNCTION: run FUNCTION and print a PASS or FAIL line for
# PROPERTY, with what FUNCTION printed if it failed.
check() {
  local property=$1 output
  if output="$("$2" 2>&1)"; then
    echo "PASS  $property"
  else
    echo "FAIL  $property"
    # shellcheck disable=SC2001 # indents every line, not just one
    [[ -z $output ]] || sed 's/^/        /' <<< "$output"
    failures=$((failures + 1))
  fi
}

# ---- Setup and cleanup -----------------------------------------------------

# Refuse to touch a project of the same name: cleanup removes every part
# with these names, so all of them must be ours.
refuse_existing_projects() {
  local project part status found=()
  for project in "$A" "$B"; do
    [[ ! -e "$(projects_dir)/$project.conf" ]] || found+=("the project $project")
    for part in $(project_parts "$project"); do
      status=0
      p4a podman "${part%%:*}" exists "${part#*:}" || status=$?
      case $status in
        0) found+=("the ${part%%:*} ${part#*:}") ;;
        1) ;;
        *) echo "Couldn't check the Sandbox machine (podman exited with $status)." >&2
           echo "  fix: start it with 'p4a machine start', and build the images with 'p4a image build'." >&2
           exit 2 ;;
      esac
    done
  done
  (( ${#found[@]} == 0 )) && return 0
  echo "The suite's throwaway projects would clash with what already exists:" >&2
  printf '  %s\n' "${found[@]}" >&2
  echo "  fix: if that's left over from an earlier run, remove it with 'p4a podman rm/network rm/volume rm'" >&2
  echo "       and delete its .conf in $(projects_dir); or pick other public repos with" >&2
  echo "       P4A_ISOLATION_REPO_A=owner/repo and P4A_ISOLATION_REPO_B=owner/repo." >&2
  exit 2
}

# Remove both throwaway projects and check nothing is left. Runs on every
# exit, after refuse_existing_projects has proven every part is ours.
cleanup() {
  local status=$? project part kind name exists file left=()
  trap - EXIT INT TERM HUP
  echo "--- Removing the throwaway projects"
  for project in "$A" "$B"; do
    # project_parts lists containers first, then the network and volumes
    # they use, so each removal is free to go ahead.
    for part in $(project_parts "$project"); do
      kind="${part%%:*}" name="${part#*:}"
      if [[ $kind == container ]]; then
        p4a podman rm -f -t 0 "$name" >/dev/null 2>&1
      else
        p4a podman "$kind" rm -f "$name" >/dev/null 2>&1
      fi
      exists=0
      p4a podman "$kind" exists "$name" || exists=$?
      case $exists in
        0) left+=("the $kind $name") ;;
        1) ;;
        *) left+=("the $kind $name (couldn't check: podman exited with $exists)") ;;
      esac
    done
    for file in "$(projects_dir)/$project.conf" "$(projects_dir)/$project.allowlist"; do
      rm -f "$file"
      [[ ! -e $file ]] || left+=("$file")
    done
  done
  if (( ${#left[@]} )); then
    echo "FAIL  cleanup: these were left behind:"
    printf '        %s\n' "${left[@]}"
    (( status )) || status=1
  else
    echo "PASS  cleanup: no throwaway project, volume, network or container is left"
  fi
  exit "$status"
}

# Create a throwaway project from REPO; stop the suite if that fails.
create_project() {
  local out
  if ! out="$(p4a new "$1" 2>&1)"; then
    echo "Couldn't create the throwaway project from $1, so no checks ran:" >&2
    # shellcheck disable=SC2001 # indents every line, not just one
    sed 's/^/  /' <<< "$out" >&2
    exit 1
  fi
}

# Start a small web server in B's Sandbox on port 8080 answering
# "sandbox-b", and check that B itself can reach it on every address.
LISTENER_PORT=8080
LISTENER_MARK=sandbox-b
start_listener_in_b() {
  script_in "$B" "$LISTENER_PORT" "$LISTENER_MARK" <<'EOF' || return 1
setsid perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr => "0.0.0.0", LocalPort => $ARGV[0],
                                Listen => 16, ReuseAddr => 1) or die "listen: $!";
  while (my $c = $s->accept) {
    # Read the request first: closing with it unread resets the connection.
    while (defined(my $line = <$c>)) { last if $line =~ /^\r?$/ }
    print $c "HTTP/1.0 200 OK\r\n\r\n$ARGV[1]\n";
    close $c;
  }
' "$1" "$2" < /dev/null > /dev/null 2>&1 &
for i in $(seq 50); do
  curl -s --noproxy '*' "http://127.0.0.1:$1" | grep -q "$2" && exit 0
  sleep 0.1
done
echo "the web server in B didn't start"
exit 1
EOF
  local ip
  for ip in $(addresses_of "podman4ai-$B"); do
    in_sandbox "$B" curl -s --noproxy '*' --max-time 5 "http://$ip:$LISTENER_PORT" | grep -q "$LISTENER_MARK" \
      || { echo "B can't reach its own web server at $ip"; return 1; }
  done
}

# ---- Checks ----------------------------------------------------------------

# A non-allowlisted domain is refused through the Egress proxy, the proxy
# logs the refusal, and there's no direct route around the proxy either.
# (example.org because the startup self-check already tries example.com.)
REFUSED_DOMAIN=example.org
non_allowlisted_domain_is_refused_and_logged() {
  local before after
  before="$(proxy_log_count "$A" "refused CONNECT $REFUSED_DOMAIN:443")" || return 1
  if in_sandbox "$A" curl -sS -o /dev/null --max-time 10 "https://$REFUSED_DOMAIN"; then
    echo "$REFUSED_DOMAIN was reachable through the Egress proxy"
    return 1
  fi
  after="$(proxy_log_count "$A" "refused CONNECT $REFUSED_DOMAIN:443")" || return 1
  if (( after <= before )); then
    echo "the Egress proxy's log has no refusal of $REFUSED_DOMAIN"
    return 1
  fi
  if in_sandbox "$A" curl -sS -o /dev/null --max-time 10 --noproxy '*' "https://$REFUSED_DOMAIN"; then
    echo "$REFUSED_DOMAIN was reachable directly, bypassing the Egress proxy"
    return 1
  fi
}

# An allowlisted domain works, and it went through the Egress proxy.
ALLOWED_DOMAIN=api.github.com
allowlisted_domain_works_through_proxy() {
  local before after
  before="$(proxy_log_count "$A" "allowed CONNECT $ALLOWED_DOMAIN:443")" || return 1
  in_sandbox "$A" curl -sS -o /dev/null --max-time 20 "https://$ALLOWED_DOMAIN" || return 1
  after="$(proxy_log_count "$A" "allowed CONNECT $ALLOWED_DOMAIN:443")" || return 1
  if (( after <= before )); then
    echo "$ALLOWED_DOMAIN was reached, but the Egress proxy's log doesn't show it allowing it"
    return 1
  fi
}

# p4a blocked lists the domain A just failed to reach. Runs after
# non_allowlisted_domain_is_refused_and_logged, which tries it.
blocked_lists_a_refused_domain() {
  local out
  out="$(p4a blocked "$A" 2>&1)" || { echo "p4a blocked failed: $out"; return 1; }
  grep -qE "^ +[0-9]+  $REFUSED_DOMAIN$" <<< "$out"     || { echo "p4a blocked doesn't list $REFUSED_DOMAIN:"; echo "$out"; return 1; }
}

# Succeed once PROJECT's Sandbox can (WANT=yes) or can't (WANT=no) reach
# https://DOMAIN, trying for up to 15 seconds.
wait_until_reachable() {
  local project=$1 domain=$2 want=$3 got deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    got=no
    in_sandbox "$project" curl -sS -o /dev/null --max-time 5 "https://$domain" 2>/dev/null && got=yes
    [[ $got == "$want" ]] && return 0
    sleep 1
  done
  return 1
}

# p4a allow opens a domain for A within seconds, without restarting
# anything, and not for B; p4a disallow closes it again.
allow_applies_live_and_only_to_its_project() {
  local out started
  started="$(p4a podman container inspect --format '{{.State.StartedAt}}' "podman4ai-$A" "podman4ai-$A-proxy")"
  out="$(p4a allow "$A" "$REFUSED_DOMAIN" 2>&1)" || { echo "p4a allow failed: $out"; return 1; }
  wait_until_reachable "$A" "$REFUSED_DOMAIN" yes     || { echo "$REFUSED_DOMAIN is still unreachable from $A 15 seconds after 'p4a allow'"; return 1; }
  if in_sandbox "$B" curl -sS -o /dev/null --max-time 10 "https://$REFUSED_DOMAIN" 2>/dev/null; then
    echo "$REFUSED_DOMAIN, allowed only for $A, was reachable from $B"
    return 1
  fi
  out="$(p4a disallow "$A" "$REFUSED_DOMAIN" 2>&1)" || { echo "p4a disallow failed: $out"; return 1; }
  wait_until_reachable "$A" "$REFUSED_DOMAIN" no     || { echo "$REFUSED_DOMAIN is still reachable from $A 15 seconds after 'p4a disallow'"; return 1; }
  [[ "$(p4a podman container inspect --format '{{.State.StartedAt}}' "podman4ai-$A" "podman4ai-$A-proxy")" == "$started" ]]     || { echo "$A's Sandbox or Egress proxy was restarted"; return 1; }
}

# No name lookups: not through the Sandbox's resolver, and not by asking a
# public DNS server directly.
outside_dns_fails() {
  script_in "$A" <<'EOF'
status=0
if out="$(getent hosts example.com)"; then
  echo "example.com resolved: $out"
  status=1
fi
# A DNS query for example.com, type A, sent straight to a public resolver.
query='\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
for server in 1.1.1.1 8.8.8.8; do
  got="$(timeout 5 bash -c 'exec 3<>"/dev/udp/$1/53" && printf "$2" >&3 && head -c 2 <&3 | wc -c' _ "$server" "$query" 2>/dev/null)"
  if [[ ${got:-0} -gt 0 ]]; then
    echo "the DNS server $server answered"
    status=1
  fi
done
exit $status
EOF
}

# The only mounts are the container's own system files and the project's
# own two volumes; nothing is shared from the Host or the Sandbox machine.
no_host_path_is_visible() {
  script_in "$A" "$A" <<'EOF'
status=0
while read -r _ _ _ root point rest; do
  fstype="${rest#* - }"
  fstype="${fstype%% *}"
  case $fstype in
    9p | virtiofs | drvfs | cifs | smb* | nfs* | fuse*)
      echo "$point is a $fstype file share"; status=1 ;;
  esac
  case $point in
    / | /proc | /proc/* | /sys | /sys/* | /dev | /dev/*) ;;
    /etc/hosts | /etc/hostname | /etc/resolv.conf | /run/.containerenv | /run/secrets | /run/podman-init) ;;
    # The tokens (#8): each a Podman secret of this project's, from the
    # Sandbox machine's own container storage.
    /run/secrets/agent-token)
      [[ $root == */containers/storage/*/userdata/secrets/podman4ai-agent-token ]] \
        || { echo "$point comes from $root, not the Agent token secret"; status=1; } ;;
    /run/secrets/repo-token)
      [[ $root == */containers/storage/*/userdata/secrets/podman4ai-"$1"-repo-token ]] \
        || { echo "$point comes from $root, not $1's Repo token secret"; status=1; } ;;
    /workspace | /home/agent/.claude)
      [[ $root == */containers/storage/volumes/podman4ai-"$1"-*/_data ]] \
        || { echo "$point comes from $root, not one of $1's volumes"; status=1; } ;;
    *) echo "unexpected mount $point, from $root ($fstype)"; status=1 ;;
  esac
done < /proc/self/mountinfo
for path in /mnt/[a-zA-Z] /[a-zA-Z] /host /Users /Windows; do
  [[ ! -e $path ]] || { echo "$path exists"; status=1; }
done
exit $status
EOF
}

user_is_not_root() {
  local uid
  uid="$(in_sandbox "$A" id -u)" || return 1
  [[ $uid != 0 ]] || { echo "the Sandbox runs as root ($(in_sandbox "$A" id))"; return 1; }
}

user_has_no_capabilities() {
  script_in "$A" <<'EOF'
status=0
while read -r name value; do
  [[ $value =~ ^0+$ ]] || { echo "$name $value"; status=1; }
done < <(grep '^Cap' /proc/self/status)
exit $status
EOF
}

user_has_no_sudo() {
  script_in "$A" <<'EOF'
found="$(command -v sudo; find / -xdev -name sudo \( -type f -o -type l \) 2>/dev/null)"
[[ -z $found ]] || { echo "sudo found: $found"; exit 1; }
EOF
}

no_new_privileges_is_set() {
  local value
  value="$(in_sandbox "$A" grep '^NoNewPrivs:' /proc/self/status)" || return 1
  [[ $value =~ NoNewPrivs:[[:space:]]+1 ]] || { echo "$value"; return 1; }
}

# No socket that looks like, or answers as, a Podman or Docker API, no
# mount of one, and no setting pointing at one. A mounted socket SELinux
# won't let the Sandbox use still fails: a relabel would make it usable,
# and SELinux hides its type, so it's also found by name and by mount.
no_podman_socket() {
  script_in "$A" <<'EOF'
status=0
for var in CONTAINER_HOST DOCKER_HOST; do
  [[ -z ${!var:-} ]] || { echo "$var=${!var}"; status=1; }
done
while read -r _ _ _ _ point _; do
  [[ ${point,,} != *podman*.sock && ${point,,} != *docker*.sock ]] || { echo "mount $point"; status=1; }
done < /proc/self/mountinfo
while IFS= read -r socket; do
  if [[ ${socket,,} == *podman* || ${socket,,} == *docker* ]]; then
    echo "socket $socket"; status=1
  elif curl -s --max-time 3 --unix-socket "$socket" http://d/_ping 2>/dev/null | grep -q OK; then
    echo "socket $socket answers as a container API"; status=1
  fi
done < <(find / \( -path /proc -o -path /sys \) -prune -o \( -name '*.sock' -o -type s \) -print 2>/dev/null | sort -u)
exit $status
EOF
}

# A can't open a connection to any address of B's Sandbox or B's Egress
# proxy, directly or through A's own Egress proxy. B's Sandbox runs a web
# server for this, which B itself can reach (start_listener_in_b).
sandbox_a_cannot_reach_b() {
  local targets=() ip
  for ip in $(addresses_of "podman4ai-$B"); do targets+=("$ip:$LISTENER_PORT"); done
  for ip in $(addresses_of "podman4ai-$B-proxy"); do targets+=("$ip:$PROXY_PORT"); done
  (( ${#targets[@]} )) || { echo "couldn't find B's addresses"; return 1; }
  script_in "$A" "${targets[@]}" <<'EOF'
status=0
for target in "$@"; do
  if timeout 5 bash -c 'exec 3<>"/dev/tcp/${1%:*}/${1#*:}"' _ "$target" 2>/dev/null; then
    echo "A connected directly to $target"; status=1
  fi
  # -p: ask A's proxy for a tunnel, which succeeds only if it connects.
  if curl -p -s -o /dev/null --max-time 10 "http://$target" 2>/dev/null; then
    echo "A connected to $target through its Egress proxy"; status=1
  fi
done
exit $status
EOF
}

# Fork sleeping children until fork fails, up to a bound just above the
# limit, then kill them all. Passes if the Sandbox's process limit is at
# most 4096 and fork failed when the Sandbox reached it, not before (which
# would mean something else stopped it).
PROCESS_LIMIT=4096
process_limit_is_in_effect() {
  local out max forked
  out="$(script_in "$A" "$PROCESS_LIMIT" <<'EOF'
cat /sys/fs/cgroup/pids.max
perl -e '
  my ($limit, @kids) = ($ARGV[0]);
  for (1 .. $limit + 100) {
    my $pid = fork;
    last unless defined $pid;
    if ($pid == 0) { sleep 120; exit 0 }
    push @kids, $pid;
  }
  kill "KILL", @kids;
  waitpid($_, 0) for @kids;
  print scalar(@kids), "\n";
' "$1"
EOF
)" || { echo "the fork test didn't finish: $out"; return 1; }
  { read -r max; read -r forked; } <<< "$out"
  [[ $forked =~ ^[0-9]+$ ]] || { echo "unexpected output: $out"; return 1; }
  [[ $max =~ ^[0-9]+$ ]] || { echo "the Sandbox has no process limit (pids.max is $max)"; return 1; }
  (( max <= PROCESS_LIMIT )) || { echo "the process limit is $max, above $PROCESS_LIMIT"; return 1; }
  (( forked < max )) || { echo "forked $forked processes without hitting the limit of $max"; return 1; }
  # A few processes (init, sleep, the shell, perl) already count.
  (( forked >= max - 20 )) \
    || { echo "fork failed after $forked processes, well below the limit of $max"; return 1; }
}

# Allocate and fill memory in 64 MiB steps up to 4.5 GiB. With a 4 GiB
# limit the kernel kills it first. (The Sandbox machine has no swap.) The
# steps are paced so Hyper-V's dynamic memory can grow the machine.
#
# The Sandbox machine's kernel log must then show the kill was by the
# Sandbox's own memory limit: a kill because the whole machine ran out of
# memory looks the same from inside but proves nothing. (The limit is on a
# parent cgroup the Sandbox can't see, so it can't tell from inside.) That
# fails at once rather than retrying, since running the whole machine out
# of memory can kill processes in other containers.
memory_limit_is_in_effect() {
  local id log last out status=0 new wait limit_kill
  id="$(p4a podman container inspect --format '{{.Id}}' "podman4ai-$A")" || return 1
  limit_kill="CONSTRAINT_MEMCG.*/libpod-$id\.scope"
  log="$(oom_log)" || { echo "$log"; return 1; }
  last="$(tail -n 1 <<< "$log")"
  out="$(in_sandbox "$A" perl -MTime::HiRes=sleep \
    -e 'my @a; for (1 .. 72) { push @a, "x" x (64 << 20); sleep 0.25 } print "allocated\n"' 2>&1)" \
    || status=$?
  if [[ $out == *allocated* ]]; then
    echo "allocated 4.5 GiB without hitting a memory limit"
    return 1
  fi
  # The kill can reach the log a moment after the Sandbox reports it.
  for (( wait = 0; wait < 10; wait++ )); do
    new="$(oom_log_after "$last")" || { echo "$new"; return 1; }
    grep -qE -- "$limit_kill" <<< "$new" && return 0
    if grep -q CONSTRAINT_NONE <<< "$new"; then
      echo "the whole Sandbox machine ran out of memory before the Sandbox reached its limit."
      echo "Hyper-V's dynamic memory may be keeping the machine too small; see 'Get-VMMemory podman4ai'."
      return 1
    fi
    sleep 1
  done
  echo "the allocation stopped (exit $status), but the kernel log shows no out-of-memory kill: $out"
  return 1
}

# The out-of-memory kills in the Sandbox machine's kernel log, one per line,
# each starting with its timestamp.
oom_log() {
  local log
  log="$(p4a podman machine ssh podman4ai sudo dmesg 2>&1)" \
    || { echo "couldn't read the Sandbox machine's kernel log: $log"; return 1; }
  grep -E 'oom-kill:constraint=' <<< "$log" || true
}

# oom_log_after LINE: the kills logged after LINE (all of them if LINE is
# empty or has scrolled out). Counting won't do: each kill's long report
# pushes older ones out of the kernel's log buffer.
oom_log_after() {
  local log
  log="$(oom_log)" || { echo "$log"; return 1; }
  if [[ -n $1 ]] && grep -qxF -- "$1" <<< "$log"; then
    awk -v last="$1" 'seen { print } $0 == last { seen = 1 }' <<< "$log"
  else
    echo "$log"
  fi
}

# This suite, run inside a Sandbox, stops at once with a clear message.
suite_refuses_inside_a_sandbox() {
  local out status=0
  out="$(script_in "$A" < "$self" 2>&1)" || status=$?
  (( status != 0 )) || { echo "it ran inside the Sandbox and exited 0: $out"; return 1; }
  [[ $out == *"can't run inside a Sandbox"* ]] || { echo "no clear refusal: $out"; return 1; }
}

# ---- Main ------------------------------------------------------------------

main() {
  refuse_existing_projects
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  echo "--- Creating the throwaway projects $A ($REPO_A) and $B ($REPO_B)"
  create_project "$REPO_A"
  create_project "$REPO_B"
  local out
  out="$(start_listener_in_b 2>&1)" || { echo "Couldn't set up B for the checks: $out" >&2; exit 1; }

  echo "--- Checks"
  check "a non-allowlisted domain is refused, and the refusal is in the Egress proxy's log" \
    non_allowlisted_domain_is_refused_and_logged
  check "an allowlisted domain works through the Egress proxy" allowlisted_domain_works_through_proxy
  check "p4a blocked lists a domain the Sandbox just failed to reach" blocked_lists_a_refused_domain
  check "p4a allow opens a domain within seconds, without a restart, only for its own project; p4a disallow closes it"     allow_applies_live_and_only_to_its_project
  check "outside DNS lookups fail" outside_dns_fails
  check "no Windows drive or Host path is visible inside the Sandbox" no_host_path_is_visible
  check "the user is not root" user_is_not_root
  check "the user has no capabilities" user_has_no_capabilities
  check "the user has no sudo" user_has_no_sudo
  check "no-new-privileges is set, so no program can gain privileges" no_new_privileges_is_set
  check "no Podman socket exists inside the Sandbox" no_podman_socket
  check "Sandbox A cannot reach Sandbox B or B's Egress proxy" sandbox_a_cannot_reach_b
  check "the process limit is in effect" process_limit_is_in_effect
  check "the memory limit is in effect" memory_limit_is_in_effect
  check "the suite refuses to run inside a Sandbox" suite_refuses_inside_a_sandbox

  echo
  if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
  fi
  echo "All checks passed"
}

main "$@"
