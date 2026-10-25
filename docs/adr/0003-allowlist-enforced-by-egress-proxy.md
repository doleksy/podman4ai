# The Allowlist is enforced by an Egress proxy, not a firewall inside the Sandbox

Sandboxes sit on an internal Podman network with no route out; their only path to the internet is an Egress proxy container that permits connections to allowlisted domain names and refuses everything else. Anthropic's reference devcontainer instead runs iptables inside the container (granting it `NET_ADMIN`), which puts the firewall under the control of the very container it guards, allows SSH and DNS to any destination, and allowlists by IP addresses resolved once at startup. A proxy outside the Sandbox enforces by domain name, removes outbound DNS, and logs every connection attempt.

## Consequences

- Git uses HTTPS (with the Repo token), never SSH.
- Image builds also go through an Egress proxy: the Base image with its own build Allowlist, a Project image with that project's Allowlist. No build has open internet.
- Tools that ignore `HTTPS_PROXY` cannot reach the network until configured; this fails closed.
- Keep the reference's startup self-check idea: verify an allowlisted domain is reachable and a non-allowlisted one is not.
- **Accepted residual risk:** filtering is by domain only, so an allowlisted service is fully reachable. A prompt injection that supplies its own credentials could push to an attacker's GitHub repo, create a gist, or `npm publish`. Sensitive projects mitigate by holding no Repo token and nothing private in the Project volume.
- The Egress proxy is a replaceable component: a TLS-inspecting proxy that filters by URL path (e.g. only the user's own repos) may replace it later without changes on the Sandbox side.
