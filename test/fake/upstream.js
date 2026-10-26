// Stand-in web server for the Egress proxy tests: answers every request
// with the path and Host header it received, so a test can see that the
// proxy delivered it, except /reset-mid-response, which breaks off its
// reply. Prints its port once it is listening.
const http = require("http");

const server = http.createServer((req, res) => {
  if (req.url === "/reset-mid-response") {
    // Start a long reply, then drop the connection abruptly.
    res.writeHead(200, { "content-type": "text/plain", "content-length": "1000" });
    res.write("partial");
    setTimeout(() => req.socket.resetAndDestroy(), 50);
    return;
  }
  res.writeHead(200, { "content-type": "text/plain" });
  res.end(`hello from upstream: ${req.method} ${req.url} host=${req.headers.host}\n`);
});
server.listen(0, "127.0.0.1", () => {
  console.log(`listening on port ${server.address().port}`);
});
