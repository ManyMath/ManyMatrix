import assert from 'node:assert/strict';
import {createReadStream, existsSync} from 'node:fs';
import {stat} from 'node:fs/promises';
import {createServer} from 'node:http';
import {dirname, extname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

import puppeteer from 'puppeteer';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const appPkg = join(repoRoot, 'apps/ManyMatrix/web/pkg');
const cratePkg = join(repoRoot, 'crates/web/pkg');
const pkgDirectory = existsSync(join(appPkg, 'manymatrix_web_bg.wasm'))
  ? appPkg
  : cratePkg;
const routes = new Map([
  [
    '/manymatrix_worker.js',
    join(repoRoot, 'apps/ManyMatrix/web/manymatrix_worker.js'),
  ],
  [
    '/manymatrix_worker_protocol.mjs',
    join(repoRoot, 'apps/ManyMatrix/web/manymatrix_worker_protocol.mjs'),
  ],
  ['/pkg/manymatrix_web.js', join(pkgDirectory, 'manymatrix_web.js')],
  [
    '/pkg/manymatrix_web_bg.wasm',
    join(pkgDirectory, 'manymatrix_web_bg.wasm'),
  ],
]);

const mimeTypes = {
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
};
const servedRequests = [];

const server = createServer(async (request, response) => {
  servedRequests.push(request.url);
  if (request.url === '/') {
    response.writeHead(200, {'content-type': 'text/html; charset=utf-8'});
    response.end('<!doctype html><title>ManyMatrix Worker smoke</title>');
    return;
  }
  const path = routes.get(request.url);
  if (!path) {
    response.writeHead(404).end();
    return;
  }
  const info = await stat(path);
  response.writeHead(200, {
    'content-length': info.size,
    'content-type': mimeTypes[extname(path)] ?? 'application/octet-stream',
  });
  createReadStream(path).pipe(response);
});

await new Promise((resolveListen) =>
  server.listen(0, '127.0.0.1', resolveListen),
);
const {port} = server.address();
let browser;
try {
  browser = await puppeteer.launch({
    ...(process.env.CHROME_BIN
      ? {executablePath: process.env.CHROME_BIN}
      : {}),
    headless: true,
    args: ['--no-sandbox'],
  });
  const page = await browser.newPage();
  const browserErrors = [];
  page.on('pageerror', (error) => browserErrors.push(error.message));
  await page.goto(`http://127.0.0.1:${port}/`);

  const result = await page.evaluate(async () => {
    const worker = new Worker('/manymatrix_worker.js', {type: 'module'});
    const messages = [];
    worker.onmessage = (event) => messages.push(event.data);
    worker.onerror = (event) => {
      event.preventDefault();
      messages.push({
        type: 'worker-error',
        message: String(event.message),
        filename: String(event.filename),
        lineno: event.lineno,
        colno: event.colno,
      });
    };
    const waitFor = (predicate, description) =>
      new Promise((resolve, reject) => {
        const deadline = Date.now() + 30_000;
        const poll = () => {
          const match = messages.find(predicate);
          if (match) return resolve(match);
          if (Date.now() >= deadline) {
          return reject(
            new Error(
              `timed out waiting for ${description}: ${JSON.stringify(messages)}`,
            ),
          );
          }
          setTimeout(poll, 20);
        };
        poll();
      });

    await waitFor((message) => message.type === 'manymatrix-ready', 'ready');
    worker.postMessage({
      type: 'manymatrix-call',
      id: 1,
      method: 'dispatcher.echo',
      args: {message: 'ordinary-browser'},
    });
    const echo = await waitFor(
      (message) => message.type === 'manymatrix-result' && message.id === 1,
      'echo result',
    );
    worker.postMessage({type: 'manymatrix-close'});
    await waitFor(
      (message) => message.type === 'manymatrix-closed',
      'closed',
    );
    return echo.ok;
  });

  assert.equal(result.message, 'ordinary-browser');
  assert.deepEqual(browserErrors, []);
  console.log('ordinary Worker init, RPC, and lifecycle smoke passed');
} catch (error) {
  console.error(`served requests: ${JSON.stringify(servedRequests)}`);
  throw error;
} finally {
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}
