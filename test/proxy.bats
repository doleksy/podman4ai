#!/usr/bin/env bats
# The Egress proxy: allows HTTPS (CONNECT) and HTTP only to Allowlist
# domains, refuses the rest naming the domain, and logs every attempt.

load proxy-helpers

@test "an HTTPS request to a domain not on the Allowlist is refused, naming the domain" {
  start_proxy "localhost"
  run through_proxy connect "example.com:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 403 "*"example.com is not on the Allowlist"* ]]
  [[ "$output" == *"example.com is not on the Allowlist"* ]]
  [[ "$(proxy_log)" == "refused CONNECT example.com:$UPSTREAM_PORT not on the Allowlist" ]]
}

@test "an HTTPS request to an Allowlist domain is tunnelled through and logged" {
  start_proxy "example.org localhost"
  run through_proxy connect "localhost:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  [[ "$output" == *"hello from upstream: GET /through-tunnel"* ]]
  [[ "$(proxy_log)" == "allowed CONNECT localhost:$UPSTREAM_PORT" ]]
}

@test "an HTTP request to an Allowlist domain is forwarded and logged" {
  start_proxy "localhost"
  run through_proxy get "http://localhost:$UPSTREAM_PORT/debian/dists/bookworm/Release?x=1"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  [[ "$output" == *"hello from upstream: GET /debian/dists/bookworm/Release?x=1 host=localhost:$UPSTREAM_PORT"* ]]
  [[ "$(proxy_log)" == "allowed GET localhost:$UPSTREAM_PORT" ]]
}

@test "an HTTP request to a domain not on the Allowlist is refused, naming the domain" {
  start_proxy "localhost"
  run through_proxy get "http://example.com:$UPSTREAM_PORT/"
  [[ "${lines[0]}" == "HTTP/1.1 403 "*"example.com is not on the Allowlist"* ]]
  [[ "$output" == *"podman4ai Egress proxy: example.com is not on the Allowlist"* ]]
  [[ "$(proxy_log)" == "refused GET example.com:$UPSTREAM_PORT not on the Allowlist" ]]
}

@test "an Allowlist domain that can't be reached gets 502 and is logged as failed" {
  start_proxy "nowhere.invalid"
  run through_proxy connect "nowhere.invalid:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 502 "*"nowhere.invalid"* ]]
  [[ "$(proxy_log)" == "allowed CONNECT nowhere.invalid:$UPSTREAM_PORT"$'\n'"failed CONNECT nowhere.invalid:$UPSTREAM_PORT ENOTFOUND" ]]

  run through_proxy get "http://nowhere.invalid:$UPSTREAM_PORT/"
  [[ "${lines[0]}" == "HTTP/1.1 502 "*"nowhere.invalid"* ]]
  [[ "$(proxy_log | tail -1)" == "failed GET nowhere.invalid:$UPSTREAM_PORT ENOTFOUND" ]]
}

@test "a *.domain entry allows its subdomains, but not the domain itself or lookalikes" {
  start_proxy "*.cdn.invalid"
  # Allowed names get past the Allowlist, then fail to resolve: 502, not 403.
  run through_proxy connect "a.cdn.invalid:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 502 "* ]]
  run through_proxy connect "deep.a.cdn.invalid:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 502 "* ]]

  for refused in cdn.invalid evilcdn.invalid a.cdn.invalid.evil.invalid; do
    run through_proxy connect "$refused:$UPSTREAM_PORT"
    [[ "${lines[0]}" == "HTTP/1.1 403 $refused is not on the Allowlist" ]]
  done
}

@test "an Allowlist domain is refused on a port that isn't allowed" {
  start_proxy "localhost"   # allowed ports: only the upstream's
  run through_proxy connect "localhost:22"
  [[ "${lines[0]}" == "HTTP/1.1 403 port 22 is not allowed" ]]
  run through_proxy get "http://localhost:8080/"
  [[ "${lines[0]}" == "HTTP/1.1 403 port 8080 is not allowed" ]]
  [[ "$(proxy_log)" == "refused CONNECT localhost:22 port not allowed"$'\n'"refused GET localhost:8080 port not allowed" ]]
}

@test "by default only ports 80 and 443 are allowed" {
  start_proxy "nowhere.invalid" ""   # "" means the default ports
  run through_proxy connect "nowhere.invalid:443"
  [[ "${lines[0]}" == "HTTP/1.1 502 "* ]]
  run through_proxy get "http://nowhere.invalid/"
  [[ "${lines[0]}" == "HTTP/1.1 502 "* ]]
  run through_proxy connect "nowhere.invalid:8443"
  [[ "${lines[0]}" == "HTTP/1.1 403 port 8443 is not allowed" ]]
}

@test "requests that aren't for an http:// URL or a host:port tunnel are refused, and the proxy keeps working" {
  start_proxy "localhost"
  run through_proxy raw 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'
  [[ "${lines[0]}" == "HTTP/1.1 400 "* ]]
  run through_proxy raw "GET https://localhost:$UPSTREAM_PORT/ HTTP/1.1\r\nHost: localhost\r\n\r\n"
  [[ "${lines[0]}" == "HTTP/1.1 400 "* ]]
  run through_proxy connect "localhost"
  [[ "${lines[0]}" == "HTTP/1.1 400 "* ]]
  run through_proxy connect "localhost:$UPSTREAM_PORT:extra"
  [[ "${lines[0]}" == "HTTP/1.1 400 "* ]]

  run through_proxy connect "localhost:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  [[ "$(proxy_log)" == *"refused GET / not a proxy request"* ]]
}

@test "domain names match the Allowlist ignoring case" {
  start_proxy "localhost"
  run through_proxy connect "LocalHost:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  [[ "$(proxy_log)" == "allowed CONNECT localhost:$UPSTREAM_PORT" ]]
}

@test "the proxy keeps working when clients drop their connections abruptly" {
  start_proxy "localhost"
  for i in 1 2 3 4 5; do
    through_proxy connect-and-reset "example.com:$UPSTREAM_PORT" || true
    through_proxy connect-and-reset "localhost:$UPSTREAM_PORT" || true
  done
  run through_proxy connect "localhost:$UPSTREAM_PORT"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  kill -0 "$PROXY_PID"
}

@test "the proxy keeps working when a server breaks off an HTTP reply" {
  start_proxy "localhost"
  through_proxy get "http://localhost:$UPSTREAM_PORT/reset-mid-response" || true
  sleep 0.5
  run through_proxy get "http://localhost:$UPSTREAM_PORT/after"
  [[ "${lines[0]}" == "HTTP/1.1 200 "* ]]
  kill -0 "$PROXY_PID"
}
