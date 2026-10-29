# shellcheck shell=bash
# A project's Allowlist: p4a allow, disallow and blocked.
#
# A project's effective Allowlist is the shared default
# (share/default-allowlist) plus that project's own additions, which are
# kept in its Host settings (<project>.allowlist, next to <project>.conf),
# outside every repo, so only the developer can change them (ADR 0002).
# p4a writes the effective Allowlist into the project's Egress proxy, which
# picks up changes within a few seconds (ADR 0003).

# Where a project's Egress proxy reads its Allowlist from: a file in the
# proxy container, which only p4a writes.
P4A_PROXY_ALLOWLIST_FILE=/home/node/allowlist

# One label of a domain name.
_P4A_DOMAIN_LABEL='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
# A domain name with at least two labels, optionally "*." for any subdomain.
P4A_DOMAIN_PATTERN="^(\\*\\.)?$_P4A_DOMAIN_LABEL(\\.$_P4A_DOMAIN_LABEL)+\$"

_p4a_additions_file() {
  echo "$(_p4a_projects_dir)/$1.allowlist"
}

# Create PROJECT's Allowlist additions file, with no additions yet.
_p4a_create_additions_file() {
  cat > "$(_p4a_additions_file "$1")" <<EOF
# Allowlist additions for $1: domains its Sandbox may reach besides the
# default Allowlist. Change them with 'p4a allow $1 <domain>' and
# 'p4a disallow $1 <domain>'. One domain per line; "*.example.com" allows
# any subdomain of example.com.
EOF
}

# Print PROJECT's Allowlist additions, one per line, in lower case (the
# file may have been edited by hand).
_p4a_allowlist_additions() {
  local file
  file="$(_p4a_additions_file "$1")"
  [[ -f $file ]] || return 0
  p4a_read_allowlist "$file" | tr ' A-Z' '\na-z' | grep -v '^$' || true
}

_p4a_default_allowlist() {
  p4a_read_allowlist "$P4A_HOME/share/default-allowlist" | tr ' ' '\n'
}

# Print PROJECT's effective Allowlist, one domain per line: the default,
# then the project's additions, each domain once.
_p4a_effective_allowlist() {
  { _p4a_default_allowlist; _p4a_allowlist_additions "$1"; } | awk 'NF && !seen[$0]++'
}

# _p4a_entry_allows ENTRY DOMAIN
# Succeed if the Allowlist entry ENTRY allows DOMAIN: the same name, or
# for "*.example.com" any subdomain of example.com, as in the proxy.
_p4a_entry_allows() {
  # shellcheck disable=SC2053 # a "*." entry is matched as a pattern
  [[ $2 == "$1" ]] || [[ $1 == '*.'* && $2 != '*.'* && $2 == $1 ]]
}

# If the default Allowlist allows DOMAIN, succeed and print "on the
# default Allowlist", naming the "*." entry that covers it if that's how.
_p4a_on_default_allowlist() {
  local entry
  while read -r entry; do
    _p4a_entry_allows "$entry" "$1" || continue
    [[ $entry == "$1" ]] && echo "on the default Allowlist" || echo "on the default Allowlist (as $entry)"
    return 0
  done < <(_p4a_default_allowlist)
  return 1
}

# _p4a_domain_argument DOMAIN
# Print DOMAIN in lower case, or exit if it isn't a domain name.
_p4a_domain_argument() {
  local domain="${1,,}"
  [[ $domain =~ $P4A_DOMAIN_PATTERN ]] \
    || p4a_die "'$1' isn't a domain name" \
      "give just the name, like example.org, or *.example.org for all its subdomains"
  echo "$domain"
}

p4a_allow() {
  [[ $# -eq 2 ]] || p4a_usage_error "allow needs a project name and a domain" "p4a --help"
  local project=$1 domain on_default
  _p4a_require_project "$project"
  domain="$(_p4a_domain_argument "$2")"
  [[ $domain != "$P4A_SELF_CHECK_REFUSED" ]] \
    || p4a_die "$domain can't be allowed: the Sandbox's startup self-check uses it as a domain that must be refused" \
      "if a project needs it, report this so the self-check can use another domain"
  if on_default="$(_p4a_on_default_allowlist "$domain")"; then
    echo "$domain is already $on_default, so every project may reach it."
    return 0
  fi
  if _p4a_allowlist_additions "$project" | grep -qxF -- "$domain"; then
    echo "$domain is already allowed for $project."
    return 0
  fi
  local file
  file="$(_p4a_additions_file "$project")"
  [[ -f $file ]] || _p4a_create_additions_file "$project"
  # A hand-edited file may not end its last line.
  [[ ! -s $file || -z "$(tail -c 1 "$file")" ]] || echo >> "$file"
  echo "$domain" >> "$file"
  echo "Allowed $domain for $project."
  _p4a_apply_allowlist "$project"
}

p4a_disallow() {
  [[ $# -eq 2 ]] || p4a_usage_error "disallow needs a project name and a domain" "p4a --help"
  local project=$1 domain additions on_default
  _p4a_require_project "$project"
  domain="$(_p4a_domain_argument "$2")"
  if on_default="$(_p4a_on_default_allowlist "$domain")"; then
    p4a_die "$domain is $on_default, which every project shares, so it can't be removed for $project alone" \
      "to remove it for every project, change share/default-allowlist in podman4ai"
  fi
  additions="$(_p4a_allowlist_additions "$project")"
  if ! grep -qxF -- "$domain" <<< "$additions"; then
    p4a_die "$domain isn't one of $project's Allowlist additions. Its additions: $(paste -sd ' ' - <<< "${additions:-(none)}" | sed 's/ /, /g')" \
      "name one of those, exactly as listed"
  fi
  # Keep every other line, comments included.
  local file line
  file="$(_p4a_additions_file "$project")"
  while IFS= read -r line || [[ -n $line ]]; do
    local name="${line%%#*}"
    name="${name//[[:space:]]/}"
    [[ ${name,,} == "$domain" ]] || printf '%s\n' "$line"
  done < "$file" > "$file.new"
  mv -f "$file.new" "$file"
  echo "Removed $domain from $project's Allowlist."
  _p4a_apply_allowlist "$project"
}

# Give PROJECT's Egress proxy its effective Allowlist now if it's running;
# otherwise say the change applies when the project starts.
_p4a_apply_allowlist() {
  local project=$1
  if _p4a_proxy_is_running "$project"; then
    (_p4a_push_allowlist "$project") \
      || p4a_die "the change is saved, but its running Egress proxy doesn't have it yet" \
        "run 'p4a stop $project', then 'p4a start $project'"
    echo "Its Egress proxy applies the change within a few seconds; the Sandbox keeps running."
  else
    echo "The change applies when you start it: p4a start $project"
  fi
}

# Succeed if PROJECT's Egress proxy is running. Never exits: the Sandbox
# machine may be stopped, in which case the proxy isn't running either.
_p4a_proxy_is_running() {
  _p4a_read_machines
  [[ $P4A_SANDBOX_STATE == running ]] || return 1
  [[ "$(p4a_sandbox_podman container inspect --format '{{.State.Running}}' "$(_p4a_proxy_name "$1")" 2>/dev/null)" == true ]]
}

# Write PROJECT's effective Allowlist into its running Egress proxy, as a
# new file renamed over the old one, so the proxy never reads half of it.
_p4a_push_allowlist() {
  local project=$1 proxy domains=()
  proxy="$(_p4a_proxy_name "$project")"
  mapfile -t domains < <(_p4a_effective_allowlist "$project")
  # shellcheck disable=SC2016 # expanded by sh in the proxy, not here
  p4a_sandbox_podman exec "$proxy" sh -c 'f=$1; shift; printf "%s\n" "$@" > "$f.new" && mv -f "$f.new" "$f"' \
      sh "$P4A_PROXY_ALLOWLIST_FILE" "${domains[@]}" >/dev/null \
    || p4a_die "couldn't give the Egress proxy $proxy its Allowlist (see podman's message above)" \
      "check it's running with 'p4a podman ps -a', then run 'p4a stop $project' and 'p4a start $project'"
}

# p4a blocked PROJECT
# List the domains PROJECT's Egress proxy refused for not being on the
# Allowlist, from its log, most frequent first. Domains allowed since are
# left out.
p4a_blocked() {
  [[ $# -eq 1 ]] || p4a_usage_error "blocked needs one project name" "p4a --help"
  local project=$1 proxy log
  _p4a_require_project "$project"
  p4a_require_running_sandbox_machine
  proxy="$(_p4a_proxy_name "$project")"
  log="$(p4a_sandbox_podman logs "$proxy" 2>&1)" \
    || p4a_die "couldn't read the log of the Egress proxy $proxy: $log" \
      "check it exists with 'p4a podman ps -a'"

  local allowed=() counts
  mapfile -t allowed < <(_p4a_effective_allowlist "$project")
  counts="$(_p4a_refused_domains <<< "$log" | sort | uniq -c | sort -k1,1nr -k2,2)"
  local count domain entry rows=()
  while read -r count domain; do
    [[ -n $domain ]] || continue
    for entry in "${allowed[@]}"; do
      _p4a_entry_allows "$entry" "$domain" && continue 2
    done
    rows+=("$(printf '  %d  %s' "$count" "$domain")")
  done <<< "$counts"

  if (( ${#rows[@]} == 0 )); then
    echo "The Egress proxy for $project hasn't refused any domain."
    return 0
  fi
  echo "Domains the Egress proxy for $project refused, most frequent first:"
  printf '%s\n' "${rows[@]}"
  echo "To let $project reach one: p4a allow $project <domain>"
}

# Read Egress proxy log lines on stdin and print the domain of each request
# refused for not being on the Allowlist, one per line.
_p4a_refused_domains() {
  local _time verdict _method target reason
  while read -r _time verdict _method target reason; do
    [[ $verdict == refused && $reason == "not on the Allowlist" && $target =~ ^([a-z0-9.-]+):[0-9]+$ ]] \
      && echo "${BASH_REMATCH[1]}"
  done
  return 0
}
