// The podman4ai port forwarder (ADR 0007).
//
// Run by `p4a port <project> <port>` in a container of its own, published
// to 127.0.0.1 on Windows only. It passes every connection it gets to one
// port of the project's Sandbox, and nowhere else. It logs to stdout, one
// line per connection it couldn't make:
//
//   TIME failed HOST:PORT CODE (hint)
//
// Settings, from the environment:
//   P4A_FORWARD_TO           the Sandbox's address and port, HOST:PORT
//   P4A_FORWARD_LISTEN_PORT  port to listen on (default 8080)
const net = require("net");

const target = process.env.P4A_FORWARD_TO ?? "";
const match = /^([0-9.]+):([0-9]+)$/.exec(target);
if (!match) {
  console.error(`P4A_FORWARD_TO must be HOST:PORT, not '${target}'`);
  process.exit(2);
}
const [, host, port] = match;
const listenPort = Number(process.env.P4A_FORWARD_LISTEN_PORT ?? 8080);

function log(...fields) {
  console.log([new Date().toISOString(), ...fields].join(" "));
}

const server = net.createServer((client) => {
  const sandbox = net.connect(Number(port), host);
  client.pipe(sandbox);
  sandbox.pipe(client);
  sandbox.on("error", (err) => {
    log("failed", target, err.code,
      "(is the server in the Sandbox listening on 0.0.0.0, not just 127.0.0.1?)");
    client.destroy();
  });
  client.on("error", () => sandbox.destroy());
  client.on("close", () => sandbox.destroy());
  sandbox.on("close", () => client.destroy());
});

server.listen(listenPort, () => {
  log("forwarding to", target, "listening on port", server.address().port);
});
