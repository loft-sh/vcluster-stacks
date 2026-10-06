// Local header-injecting proxy for the OpenClaw dashboard, used by local-dashboard.sh.
//
// The gateway only serves the Control UI to a proxied client with a real (non-loopback) address,
// so a plain `kubectl port-forward` is refused with proxy_attribution_required. This tiny proxy
// sits between your browser and the port-forward and adds the same headers the in-cluster nginx
// adds for an allowed external client. HTTP and WebSocket (the UI's live connection) both pass.
//
// No dependencies. Node 18+.
import http from 'node:http';
import net from 'node:net';

const listenPort = Number(process.env.LOCAL_PORT || 30789);
const target = { host: '127.0.0.1', port: Number(process.env.GATEWAY_PORT || 30790) };
const extra = {
  'x-forwarded-user': process.env.OPERATOR_USER || 'operator@openclaw.local',
  'x-forwarded-proto': 'http',
  'x-forwarded-host': `127.0.0.1:${listenPort}`,
  'x-forwarded-for': process.env.CLIENT_IP || '198.51.100.7',
};

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, ...extra };
  const up = http.request({ ...target, method: req.method, path: req.url, headers }, (pr) => {
    res.writeHead(pr.statusCode, pr.headers);
    pr.pipe(res);
  });
  up.on('error', (e) => { res.writeHead(502, { 'content-type': 'text/plain' }); res.end(`upstream error: ${e.message}`); });
  req.pipe(up);
});

server.on('upgrade', (req, socket, head) => {
  const up = net.connect(target.port, target.host, () => {
    const headers = { ...req.headers, ...extra };
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(headers)) raw += `${k}: ${v}\r\n`;
    up.write(raw + '\r\n');
    if (head && head.length) up.write(head);
    socket.pipe(up);
    up.pipe(socket);
  });
  up.on('error', () => socket.destroy());
  socket.on('error', () => up.destroy());
});

server.listen(listenPort, '127.0.0.1', () => {
  console.log(`OpenClaw dashboard: http://127.0.0.1:${listenPort}/   (Ctrl-C to stop)`);
});
