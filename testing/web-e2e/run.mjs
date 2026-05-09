// Web/extension E2E harness (Phase 25).
//
// Loads the built manymatrix Chrome extension into headless Chrome, drives
// the envelope bridge (login, rooms, send) from an injected extension page,
// and asserts that events sent by a second, native-side client (the
// web_e2e_actor test-harness binary) arrive through the push channel
// (offscreen -> chrome.runtime broadcast). Also exercises offscreen-document
// recovery.
//
// Usage: node run.mjs <hosted-synapse|hosted-tuwunel>
// Env:   MANYMATRIX_HOSTED_*   hosted-tier vars (consumed by the actor)
//        CHROME_BIN            Chrome executable (default: puppeteer's bundled
//                              Chrome for Testing, branded Chrome >=137 removed
//                              --load-extension, so plain google-chrome won't work)
//        EXTENSION_DIR         built extension (default: flutter_plugin/example/build/extension)
//        ACTOR_BIN             actor binary (default: target/debug/web_e2e_actor)

import { spawn } from 'node:child_process';
import { cp, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const serverKind = process.argv[2];
if (serverKind !== 'hosted-synapse' && serverKind !== 'hosted-tuwunel') {
  console.error('usage: node run.mjs <hosted-synapse|hosted-tuwunel>');
  process.exit(64);
}

const CHROME_BIN = process.env.CHROME_BIN; // undefined -> bundled Chrome for Testing
const EXTENSION_DIR =
  process.env.EXTENSION_DIR ?? join(repoRoot, 'flutter_plugin/example/build/extension');
const ACTOR_BIN = process.env.ACTOR_BIN ?? join(repoRoot, 'target/debug/web_e2e_actor');

const E2E_PAGE_JS = `
window.mmEvents = [];
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === 'manymatrix-event') {
    window.mmEvents.push({kind: message.kind, payload: JSON.parse(message.payload)});
  }
});
window.mmCall = (method, args) => new Promise((resolve, reject) => {
  chrome.runtime.sendMessage({method, args: args ?? {}}, (reply) => {
    if (chrome.runtime.lastError) {
      reject(new Error(chrome.runtime.lastError.message));
    } else {
      resolve(reply);
    }
  });
});
`;

const E2E_PAGE_HTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>manymatrix e2e</title></head>
<body><script src="e2e.js"></script></body></html>
`;

function log(step, detail = '') {
  console.log(`[web-e2e:${serverKind}] ${step}${detail ? ' ' + detail : ''}`);
}

function fail(message) {
  throw new Error(`[web-e2e:${serverKind}] FAIL: ${message}`);
}

// --- Actor process: JSON lines over stdin/stdout ---

class Actor {
  constructor(bin, kind) {
    this.child = spawn(bin, [kind], {stdio: ['pipe', 'pipe', 'inherit']});
    this.pending = new Map();
    this.nextId = 1;
    this.readyPromise = new Promise((resolveReady, rejectReady) => {
      this.resolveReady = resolveReady;
      this.child.on('exit', (code) =>
        rejectReady(new Error(`actor exited before ready (code ${code})`)));
    });
    // Keep an early rejection (e.g. browser launch failed first) from
    // becoming an unhandled-rejection crash; ready() still rejects.
    this.readyPromise.catch(() => {});
    createInterface({input: this.child.stdout}).on('line', (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        console.error(`[actor stdout] ${line}`);
        return;
      }
      if (message.ready) {
        this.resolveReady(message);
      } else if (this.pending.has(message.id)) {
        this.pending.get(message.id)(message);
        this.pending.delete(message.id);
      }
    });
  }

  ready() {
    return this.readyPromise;
  }

  async cmd(cmd, fields = {}) {
    const id = this.nextId++;
    const reply = await new Promise((resolveReply, rejectReply) => {
      const timer = setTimeout(
        () => rejectReply(new Error(`actor command ${cmd} timed out`)), 60_000);
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        resolveReply(message);
      });
      this.child.stdin.write(JSON.stringify({id, cmd, ...fields}) + '\n');
    });
    if (!reply.ok) fail(`actor command ${cmd} failed: ${reply.error}`);
    return reply;
  }

  async stop() {
    await this.cmd('stop');
    await new Promise((resolveExit) => this.child.on('exit', resolveExit));
  }

  kill() {
    this.child.kill('SIGKILL');
  }
}

// --- Envelope + event helpers ---

async function call(page, method, args) {
  const reply = await page.evaluate(
    (m, a) => window.mmCall(m, a), method, args ?? {});
  if (!reply || reply.err) {
    fail(`${method} returned error: ${JSON.stringify(reply?.err ?? reply)}`);
  }
  return reply.ok;
}

async function waitForEvent(page, kind, predicate, description, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const events = await page.evaluate(() => window.mmEvents);
    const match = events.find((e) => e.kind === kind && predicate(e.payload));
    if (match) return match.payload;
    await new Promise((r) => setTimeout(r, 500));
  }
  const events = await page.evaluate(() => window.mmEvents);
  fail(`timed out waiting for ${kind} event (${description}); saw ${JSON.stringify(events)}`);
}

// --- Main ---

let browser, actor, stagedExtension;
try {
  // Stage the extension with the injected e2e page so the shipping build
  // stays untouched.
  stagedExtension = await mkdtemp(join(tmpdir(), 'manymatrix-web-e2e-'));
  await cp(EXTENSION_DIR, stagedExtension, {recursive: true});
  await writeFile(join(stagedExtension, 'e2e.js'), E2E_PAGE_JS);
  await writeFile(join(stagedExtension, 'e2e.html'), E2E_PAGE_HTML);
  log('staged extension', stagedExtension);

  actor = new Actor(ACTOR_BIN, serverKind);
  browser = await puppeteer.launch({
    ...(CHROME_BIN ? {executablePath: CHROME_BIN} : {}),
    headless: true,
    args: [
      `--disable-extensions-except=${stagedExtension}`,
      `--load-extension=${stagedExtension}`,
      '--no-first-run',
      // Chrome for Testing has no AppArmor profile, so its sandbox cannot
      // start on Ubuntu 23.10+ userns restrictions. Trusted content only.
      '--no-sandbox',
    ],
  });

  const swTarget = await browser.waitForTarget(
    (t) => t.type() === 'service_worker' && t.url().startsWith('chrome-extension://'),
    {timeout: 30_000});
  const extensionId = new URL(swTarget.url()).hostname;
  log('extension loaded', extensionId);

  const info = await actor.ready();
  log('actor ready', `${info.actor_user_id} on ${info.base_url}`);

  const page = await browser.newPage();
  page.on('console', (msg) => console.error(`[page console] ${msg.text()}`));
  await page.goto(`chrome-extension://${extensionId}/e2e.html`);

  // 1. Envelope basics: echo through sw -> offscreen -> wasm and back.
  const echo = await call(page, 'dispatcher.echo', {message: 'ping'});
  if (echo.message !== 'ping') fail(`echo mismatch: ${JSON.stringify(echo)}`);
  log('1/8 dispatcher.echo ok');

  // 2. Login as the extension user.
  const storeName = `webe2e-${serverKind}-${Date.now()}`;
  const login = await call(page, 'auth.login', {
    homeserver_url: info.base_url,
    username: info.ext_localpart,
    password: info.ext_password,
    store_name: storeName,
  });
  if (login.user_id !== info.ext_user_id) {
    fail(`login user mismatch: ${login.user_id} != ${info.ext_user_id}`);
  }
  const sessionJson = login.session_json;
  log('2/8 auth.login ok', login.user_id);

  // 3. rooms.list starts empty for the fresh account, then create + invite.
  const emptyList = JSON.parse((await call(page, 'rooms.list')).rooms_json);
  if (emptyList.length !== 0) fail(`expected no rooms, got ${emptyList.length}`);
  const {room_id: roomId} = await call(page, 'rooms.create', {
    name: 'web-e2e',
    invite: [info.actor_user_id],
    public: false,
  });
  log('3/8 rooms.list + rooms.create ok', roomId);

  // 4. Subscribe to push events, start sync, actor joins.
  await call(page, 'events.subscribe');
  await call(page, 'sync.start');
  await actor.cmd('join', {room_id: roomId});
  log('4/8 events.subscribe + sync.start + actor join ok');

  // 5. Push channel: native message arrives as an onMessage broadcast.
  const nonce = Math.random().toString(36).slice(2);
  const sent = await actor.cmd('send_text', {room_id: roomId, body: `native says ${nonce}`});
  const messageEvent = await waitForEvent(
    page, 'message', (p) => p.body === `native says ${nonce}`, `body "native says ${nonce}"`);
  if (messageEvent.sender !== info.actor_user_id) {
    fail(`message sender mismatch: ${messageEvent.sender}`);
  }
  if (messageEvent.room_id !== roomId) fail(`message room mismatch: ${messageEvent.room_id}`);
  if (messageEvent.event_id !== sent.event_id) {
    fail(`message event_id mismatch: ${messageEvent.event_id} != ${sent.event_id}`);
  }
  log('5/8 push channel message ok', sent.event_id);

  // 6. Extension sends; native reacts and read-receipts that event.
  const {event_id: webEventId} =
    await call(page, 'messages.send_text', {room_id: roomId, body: 'web says hi'});
  await actor.cmd('react', {room_id: roomId, event_id: webEventId, key: '\u{1F44D}'});
  const reactionEvent = await waitForEvent(
    page, 'reaction',
    (p) => p.relates_to_event_id === webEventId && p.key === '\u{1F44D}',
    `reaction to ${webEventId}`);
  if (reactionEvent.sender !== info.actor_user_id) {
    fail(`reaction sender mismatch: ${reactionEvent.sender}`);
  }
  await actor.cmd('receipt', {room_id: roomId, event_id: webEventId});
  await waitForEvent(
    page, 'receipt',
    (p) => p.event_id === webEventId && p.user_id === info.actor_user_id,
    `receipt for ${webEventId}`);
  log('6/8 push channel reaction + receipt ok');

  // 7. Offscreen recovery: kill the offscreen document from the service
  // worker; the next envelope must transparently recreate it (fresh WASM,
  // so the client is logged out afterwards).
  const worker = await swTarget.worker();
  await worker.evaluate(() => chrome.offscreen.closeDocument());
  const echo2 = await call(page, 'dispatcher.echo', {message: 'post-recovery'});
  if (echo2.message !== 'post-recovery') fail('echo after offscreen recovery failed');
  const status = await call(page, 'sync.status');
  if (status.logged_in !== false) {
    fail(`expected logged_in=false after offscreen recovery, got ${JSON.stringify(status)}`);
  }
  log('7/8 offscreen recovery ok');

  // 8. Restore the session from the persisted IndexedDB store and confirm
  // the push channel comes back end to end.
  const restored = await call(page, 'auth.restore', {
    homeserver_url: info.base_url,
    session_json: sessionJson,
    store_name: storeName,
  });
  if (restored.user_id !== info.ext_user_id) {
    fail(`restore user mismatch: ${restored.user_id}`);
  }
  const rooms = JSON.parse((await call(page, 'rooms.list')).rooms_json);
  if (!rooms.some((r) => r.room_id === roomId)) {
    fail(`restored rooms.list missing ${roomId}: ${JSON.stringify(rooms)}`);
  }
  await call(page, 'events.subscribe');
  await call(page, 'sync.start');
  const sent2 = await actor.cmd('send_text', {room_id: roomId, body: `after recovery ${nonce}`});
  await waitForEvent(
    page, 'message', (p) => p.event_id === sent2.event_id, 'post-recovery message');
  log('8/8 restore + post-recovery push ok');

  await actor.stop();
  actor = null;
  log('PASS');
} catch (error) {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
} finally {
  actor?.kill();
  await browser?.close();
  if (stagedExtension) await rm(stagedExtension, {recursive: true, force: true});
}
