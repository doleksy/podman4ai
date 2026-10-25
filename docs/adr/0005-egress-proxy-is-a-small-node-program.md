# The Egress proxy is a small Node program of our own, not tinyproxy

The Egress proxy (ADR 0003) is `images/proxy/egress-proxy.js`, about 150 lines on Node's standard library, run from the official `node:22-alpine` image. The #3 prototype used tinyproxy, which worked, but its refusals can't name the refused domain (fixed `403 Filtered`), its log mixes request lines with filter lines (a refused CONNECT appears twice), and it can only be tested inside a container. Our own program refuses with `403 <domain> is not on the Allowlist`, writes one line per attempt (`TIME allowed|refused|failed METHOD HOST:PORT [REASON]`) that `p4a` summarises, and is unit-tested on the Host with the Node the tests already need.

## Considered Options

- tinyproxy: mature C proxy, about 1 MB. Kept as the fallback if owning a proxy becomes a burden; ADR 0003 makes the proxy replaceable, so the Sandbox side wouldn't change.

## Consequences

- We own security-relevant code. Its rules are deliberately narrow: only `CONNECT host:port` and absolute `http://` requests; only Allowlist names (`*.example.com` means subdomains only); only ports 80 and 443 by default; the connection goes to exactly the name that was checked. Unit tests cover each rule.
- The proxy image's build has no RUN steps, so `p4a image build` gives it no network at all (`--network none`). Only Podman itself pulls the `node` base image.
- The Allowlist reaches the proxy as an environment variable (`P4A_ALLOWLIST`) when its container starts, never from an image.
- Rootless Podman can't put a build on a named network (`cannot use networks as rootless`). `p4a image build` starts an idle container on the internal build network only and builds with `--network ns:<that container's network namespace>`, so build steps have no route out and no DNS, and reach the proxy at a fixed address.
