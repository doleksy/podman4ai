// The podman4ai Egress proxy (ADR 0003).
//
// A forwarding proxy that allows HTTPS (CONNECT) and plain HTTP requests
// only to domain names on its Allowlist, refuses everything else with a
// message naming the refused domain, and logs every attempt to stdout, one
// line each:
//
//   TIME allowed|refused|failed METHOD HOST:PORT [REASON]
//
// Settings, all from the environment:
//   P4A_ALLOWLIST            domains, separated by spaces or newlines;
//                            "*.example.com" allows any subdomain of
//                            example.com (but not example.com itself)
//   P4A_PROXY_LISTEN_PORT    port to listen on (default 8888)
//   P4A_PROXY_ALLOWED_PORTS  destination ports allowed (default "80 443")
const http = require("http");
const net = require("net");

const words = (value) => (value ?? "").split(/\s+/).filter(Boolean);
const allowlist = words(process.env.P4A_ALLOWLIST);
const allowedPorts = words(process.env.P4A_PROXY_ALLOWED_PORTS || "80 443");
const listenPort = Number(process.env.P4A_PROXY_LISTEN_PORT ?? 8888);

function log(...fields) {
  console.log([new Date().toISOString(), ...fields].join(" "));
}

function onAllowlist(host) {
  return allowlist.some((entry) =>
    entry.startsWith("*.") ? host.endsWith(entry.slice(1)) : host === entry,
  );
}

// Why a request to HOST:PORT is refused, or null if it's allowed. Each
// refusal has a short reason for the log and a message for the client.
function refusal(host, port) {
  if (!onAllowlist(host)) {
    return { reason: "not on the Allowlist", message: `${host} is not on the Allowlist` };
  }
  if (!allowedPorts.includes(String(port))) {
    return { reason: "port not allowed", message: `port ${port} is not allowed` };
  }
  return null;
}

// A complete reply for a raw client socket (CONNECT has no response object).
function rawReply(status, message) {
  return (
    `HTTP/1.1 ${status} ${message}\r\n` +
    "Content-Type: text/plain\r\nConnection: close\r\n\r\n" +
    `podman4ai Egress proxy: ${message}\n`
  );
}

// Headers meant for this proxy or this one connection, not for the server.
const HOP_BY_HOP = [
  "connection", "keep-alive", "proxy-connection", "proxy-authorization",
  "proxy-authenticate", "te", "trailer", "transfer-encoding", "upgrade",
];

// Plain HTTP: the request line holds the full URL.
const server = http.createServer((req, res) => {
  const reply = (status, message) => {
    res.writeHead(status, message, { "content-type": "text/plain", connection: "close" });
    res.end(`podman4ai Egress proxy: ${message}\n`);
  };
  const url = URL.parse(req.url);
  if (url?.protocol !== "http:") {
    log("refused", req.method, req.url, "not a proxy request");
    return reply(400, "only requests for http:// URLs can be proxied; use CONNECT for https");
  }
  const port = url.port || 80;
  const target = `${url.hostname}:${port}`;
  const refused = refusal(url.hostname, port);
  if (refused) {
    log("refused", req.method, target, refused.reason);
    return reply(403, refused.message);
  }
  log("allowed", req.method, target);
  const headers = { ...req.headers };
  for (const name of HOP_BY_HOP) delete headers[name];
  const upstream = http.request(
    { host: url.hostname, port, method: req.method, path: url.pathname + url.search, headers },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode, upstreamRes.statusMessage, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );
  upstream.on("error", (err) => {
    if (res.headersSent) return res.destroy();
    log("failed", req.method, target, err.code);
    reply(502, `couldn't reach ${url.hostname} (${err.code})`);
  });
  req.pipe(upstream);
});

// HTTPS: CONNECT host:port opens a tunnel; TLS stays end to end.
server.on("connect", (req, client, head) => {
  // A client may drop the connection at any moment; without a handler
  // that error would stop the proxy.
  let upstream = null;
  client.on("error", () => upstream?.destroy());
  const tunnel = /^([a-z0-9.-]+):(\d{1,5})$/i.exec(req.url);
  if (!tunnel) {
    log("refused", "CONNECT", req.url, "not a host:port tunnel");
    return client.end(rawReply(400, "CONNECT needs a domain name and port, like example.com:443"));
  }
  const host = tunnel[1].toLowerCase();
  const port = tunnel[2];
  const target = `${host}:${port}`;
  const refused = refusal(host, port);
  if (refused) {
    log("refused", "CONNECT", target, refused.reason);
    return client.end(rawReply(403, refused.message));
  }
  log("allowed", "CONNECT", target);
  let connected = false;
  upstream = net.connect(Number(port), host, () => {
    connected = true;
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
  upstream.on("error", (err) => {
    if (connected) return client.destroy();
    log("failed", "CONNECT", target, err.code);
    client.end(rawReply(502, `couldn't reach ${host} (${err.code})`));
  });
});

server.listen(listenPort, () => {
  log("listening on port", server.address().port);
});
