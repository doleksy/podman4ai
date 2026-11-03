#!/usr/bin/env bash
# Host-only check of the live sign-ins (#27) against a private test
# repository you name. Needs the Sandbox machine running, the images built,
# the Agent token stored, and a Repo token stored for the test repository's
# project. Takes a few minutes. Opt-in: without P4A_TEST_REPO it does nothing.
#
#   P4A_TEST_REPO=owner/repo test/host/sign-in.sh
#
# It creates the project with `p4a new owner/repo`, and checks:
# 1. the private repository clones on its Repo token;
# 2. Claude answers a prompt on the Agent token;
# 3. a commit made in the Sandbox carries the Host's git name and email;
# 4. a branch pushed from the Sandbox is seen on GitHub, then deleted;
# 5. no token value appears in anything it captured.
# Afterwards it deletes the test branch if it's still there and removes the
# project with `p4a rm`, keeping its Repo token, even after a failure or
# Ctrl-C. It stops before creating anything if the project already exists.
#
# Exits 0 when every check passed (or P4A_TEST_REPO isn't set), 1 when a
# check failed, 2 when a precondition stopped it.
set -uo pipefail

# Never inside a Sandbox (or any container): this check drives the Sandbox
# machine from the Host.
if [[ -e /run/.containerenv || -e /.dockerenv ]]; then
  echo "sign-in.sh: this is a Host-only check and can't run inside a Sandbox or other container." >&2
  echo "  fix: run it from Git Bash on the Host, with the Sandbox machine running." >&2
  exit 2
fi

if [[ -z ${P4A_TEST_REPO:-} ]]; then
  cat <<'EOF'
sign-in.sh: skipped, because P4A_TEST_REPO isn't set. It needs a repository
you can push to, ideally a private one used only for this, with its Repo
token stored:
  p4a secret set repo-token <project>     (the repository name, lower-cased)
Then run it with: P4A_TEST_REPO=owner/repo test/host/sign-in.sh
EOF
  exit 0
fi
if [[ ! $P4A_TEST_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "P4A_TEST_REPO must be owner/repo, not '$P4A_TEST_REPO'." >&2
  exit 2
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
p4a() { "$repo/bin/p4a" "$@"; }

# The project name, as p4a new makes it: the repository name in lower case.
project="${P4A_TEST_REPO#*/}"
project="${project,,}"
agent_secret=podman4ai-agent-token
repo_secret="podman4ai-$project-repo-token"

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

# The project's Host settings files.
settings_dir="$(projects_dir)"
project_files=("$settings_dir/$project.conf" "$settings_dir/$project.allowlist" "$settings_dir/$project.Containerfile")

# The project's Sandbox machine parts, as "kind:name", containers first so
# each removal is free to go ahead.
project_parts() {
  echo "container:podman4ai-$project" "container:podman4ai-$project-proxy" \
    "network:podman4ai-$project" \
    "volume:podman4ai-$project-source" "volume:podman4ai-$project-claude"
}

# Whether the KIND NAME exists: 0 yes, 1 no; stops the check if podman
# can't say.
part_exists() {
  local status=0
  p4a podman "$1" exists "$2" || status=$?
  (( status <= 1 )) && return "$status"
  echo "Couldn't check the Sandbox machine (podman exited with $status)." >&2
  echo "  fix: start it with 'p4a machine start', and build the images with 'p4a image build'." >&2
  exit 2
}

# ---- Preconditions, before creating anything --------------------------------

missing=()
part_exists secret "$agent_secret" || missing+=("p4a secret set agent-token")
part_exists secret "$repo_secret" || missing+=("p4a secret set repo-token $project")
if (( ${#missing[@]} )); then
  echo "This check signs in with real tokens, and these aren't stored yet. Set them with:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 2
fi

found=()
for file in "${project_files[@]}"; do
  [[ ! -e $file ]] || found+=("$file")
done
for part in $(project_parts); do
  ! part_exists "${part%%:*}" "${part#*:}" || found+=("the ${part%%:*} ${part#*:}")
done
if (( ${#found[@]} )); then
  echo "The project $project already exists, and this check would replace it:" >&2
  printf '  %s\n' "${found[@]}" >&2
  echo "  fix: if it's left over from an earlier run, remove it with 'p4a rm $project' (its Repo token is kept)." >&2
  exit 2
fi

# ---- Checks -----------------------------------------------------------------

failures=0
pass() { echo "PASS  $*"; }
fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}
# Show OUTPUT under a FAIL line, indented.
show() {
  # shellcheck disable=SC2001 # indents every line, not just one
  [[ -z $1 ]] || sed 's/^/        /' <<< "$1"
}

tmp="$(mktemp -d)"
created=0  # this run ran p4a new, so the project is its own to remove
branch="p4a-check-$(date +%Y%m%d%H%M%S)-$RANDOM$RANDOM"
pushed=0   # the test branch may be on GitHub
deleted=0  # ...and was deleted again

# Run COMMAND with no input, putting its stdout in $out and its stderr in
# $err, and keeping both for the token check.
captured=""
run() {
  local status=0
  out="$("$@" < /dev/null 2> "$tmp/err")" || status=$?
  err="$(< "$tmp/err")"
  captured+="$out"$'\n'"$err"$'\n'
  return "$status"
}
in_sandbox() { run p4a shell "$project" -- "$@"; }

# Whether the test branch is on GitHub: 0 yes, 1 no, 2 couldn't tell.
branch_on_github() {
  in_sandbox git ls-remote --heads origin "refs/heads/$branch" || return 2
  [[ $out == *"refs/heads/$branch"* ]]
}

# Delete the test branch if it's on GitHub, remove the project but keep its
# Repo token, and check nothing is left. Runs on every exit, and only
# removes what this run created.
cleanup() {
  local status=$? left=() part kind name file exists
  trap - EXIT INT TERM HUP
  if (( created )); then
    echo "--- Cleaning up"
    if (( pushed && ! deleted )); then
      local on_github=0
      branch_on_github || on_github=$?
      if (( on_github != 1 )); then
        in_sandbox git push -q origin --delete "$branch" || true
        branch_on_github && left+=("the branch $branch on $P4A_TEST_REPO; delete it with 'git push origin --delete $branch'")
      fi
    fi

    # p4a rm asks for the project name before deleting its volumes.
    if ! p4a rm "$project" <<< "$project" > "$tmp/rm" 2>&1; then
      echo "p4a rm $project failed; removing what's left directly:"
      show "$(< "$tmp/rm")"
    fi
    # After a successful p4a rm, nothing is left to remove here.
    for part in $(project_parts); do
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
    p4a podman image rm --ignore "localhost/podman4ai-project-$project" >/dev/null 2>&1
    for file in "${project_files[@]}"; do
      rm -f "$file"
      [[ ! -e $file ]] || left+=("$file")
    done

    if (( ${#left[@]} )); then
      echo "FAIL  cleanup: these were left behind:"
      printf '        %s\n' "${left[@]}"
      (( status )) || status=1
    else
      echo "PASS  cleanup: no test branch, project, container, network or volume is left"
    fi
    if p4a podman secret exists "$repo_secret"; then
      echo "PASS  cleanup: the Repo token is still stored, for the next run"
    else
      echo "FAIL  cleanup: the Repo token is gone; store it again with 'p4a secret set repo-token $project'"
      (( status )) || status=1
    fi
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "--- 1. The private repository clones on its Repo token"
created=1
if run p4a new "$P4A_TEST_REPO" && in_sandbox git rev-parse --verify -q HEAD; then
  pass "p4a new $P4A_TEST_REPO cloned it"
else
  fail "p4a new $P4A_TEST_REPO didn't clone it, so no other check ran"
  show "$err"
  exit 1
fi

echo "--- 2. Claude answers on the Agent token"
if in_sandbox claude -p "say hello" && [[ -n ${out//[[:space:]]/} ]]; then
  pass "claude -p answered"
elif [[ -z ${out//[[:space:]]/} && -z $err ]]; then
  fail "claude -p exited 0 but gave no answer"
else
  fail "claude -p failed"
  show "$err"
fi

echo "--- 3. A commit in the Sandbox carries the Host's git identity"
host_name="$(git config --global --get user.name)"
host_email="$(git config --global --get user.email)"
expected="$host_name <$host_email>"$'\n'"$host_name <$host_email>"
# shellcheck disable=SC2016 # $1 is expanded by sh in the Sandbox
if in_sandbox sh -c 'git switch -q -c "$1" && git commit -q --allow-empty -m "p4a sign-in check" && git log -1 --format="%an <%ae>%n%cn <%ce>"' _ "$branch"; then
  if [[ $out == "$expected" ]]; then
    pass "the commit's author and committer are $host_name <$host_email>"
  else
    fail "the commit's author and committer aren't the Host's $host_name <$host_email>:"
    show "$out"
  fi
else
  fail "couldn't make a commit on $branch"
  show "$err"
fi

echo "--- 4. A branch pushed from the Sandbox reaches GitHub, and is deleted again"
pushed=1
if in_sandbox git push -q -u origin "$branch"; then
  pass "pushed $branch"
  if branch_on_github; then
    pass "git ls-remote lists $branch"
  else
    fail "git ls-remote doesn't list $branch"
    show "$err"
  fi
  if in_sandbox git push -q origin --delete "$branch"; then
    status=0
    branch_on_github || status=$?
    if (( status == 1 )); then
      deleted=1
      pass "deleted $branch, and git ls-remote no longer lists it"
    else
      fail "deleted $branch, but git ls-remote still lists it (or couldn't tell)"
      show "$err"
    fi
  else
    fail "couldn't delete $branch"
    show "$err"
  fi
else
  fail "couldn't push $branch"
  show "$err"
fi

echo "--- 5. No token value appears in the output"
leaked=0 unreadable=0
for secret in "$agent_secret" "$repo_secret"; do
  value="$(p4a podman secret inspect --showsecret --format '{{.SecretData}}' "$secret" 2>/dev/null)"
  if [[ -z $value ]]; then
    unreadable=$((unreadable + 1))
  elif [[ $captured == *"$value"* ]]; then
    leaked=$((leaked + 1))
  fi
done
unset value
if (( unreadable )); then
  fail "couldn't read $unreadable stored token(s) to look for them"
elif (( leaked )); then
  fail "$leaked token value(s) appear in the output"
else
  pass "neither token's value appears in the output"
fi

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
