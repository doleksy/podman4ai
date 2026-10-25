// Test client for the Egress proxy. Speaks raw HTTP so tests control
// exactly what the proxy receives.
//
//   node proxy-client.js PROXY_PORT connect HOST:PORT
//     CONNECT through the proxy. If the tunnel opens, send a plain HTTP
//     GET through it.
//   node proxy-client.js PROXY_PORT get URL
//     A plain HTTP proxy request for URL.
//   node proxy-client.js PROXY_PORT connect-and-reset HOST:PORT
//     CONNECT, then reset the connection without waiting for a reply.
//   node proxy-client.js PROXY_PORT raw TEXT
//     Send TEXT (with \r\n escapes) as is.
//
// Prints the proxy's status line, then the body it or the upstream sent.
const net = require("net");

const [proxyPort, mode, target] = process.argv.slice(2);

const socket = net.connect(Number(proxyPort), "127.0.0.1");
let received = "";
let tunnelled = false;

socket.on("connect", () => {
  if (mode === "connect") {
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);
  } else if (mode === "get") {
    const host = new URL(target).host;
    socket.write(`GET ${target} HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
  } else if (mode === "connect-and-reset") {
    // Ask for a tunnel, then drop the connection abruptly (TCP reset)
    // before the proxy answers.
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);
    socket.resetAndDestroy();
  } else if (mode === "raw") {
    socket.write(target.replace(/\\r\\n/g, "\r\n"));
  } else {
    console.error(`unknown mode ${mode}`);
    process.exit(2);
  }
});

socket.on("data", (chunk) => {
  received += chunk.toString("utf8");
  // Once the tunnel is open, talk to whatever is on the other end.
  if (mode === "connect" && !tunnelled && /^HTTP\/1\.1 200[^\r]*\r\n\r\n/.test(received)) {
    tunnelled = true;
    const [host] = target.split(":");
    socket.write(`GET /through-tunnel HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
  }
});

socket.on("error", (err) => {
  received += `\n(client error: ${err.code})`;
});

socket.on("close", () => {
  const [head, ...rest] = received.split("\r\n\r\n");
  console.log(head.split("\r\n")[0]);
  const body = rest.join("\r\n\r\n").trim();
  if (body) console.log(body);
});

setTimeout(() => {
  console.log(received.split("\r\n")[0] || "(no reply)");
  console.log("(timed out)");
  process.exit(1);
}, 10000).unref();
