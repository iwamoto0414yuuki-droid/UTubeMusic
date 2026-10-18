import http from 'node:http';
import { readFile } from 'node:fs/promises';
http.createServer(async (req, res) => {
  if (req.url !== '/' && req.url !== '/index.html') { res.writeHead(404).end(); return; }
  try {
    const page = await readFile(new URL('./index.html', import.meta.url));
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(page);
  } catch { res.writeHead(500).end('Preview file unavailable'); }
}).listen(8876, '127.0.0.1', () => console.log('UTube Music design preview: http://127.0.0.1:8876/'));
