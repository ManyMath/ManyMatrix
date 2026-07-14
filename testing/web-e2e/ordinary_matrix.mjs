// Deterministic ordinary-site E2E: real browser Workers + WASM against the
// in-process Tuwunel tier. No hosted credentials or extension APIs.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createReadStream, existsSync} from 'node:fs';
import {stat} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {dirname, extname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

import puppeteer from 'puppeteer';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const actorBinary =
  process.env.ACTOR_BIN ?? join(repoRoot, 'target/debug/web_e2e_actor');
const appPkg = join(repoRoot, 'apps/ManyMatrix/web/pkg');
const cratePkg = join(repoRoot, 'crates/web/pkg');
const pkgDirectory = existsSync(join(appPkg, 'manymatrix_web_bg.wasm'))
  ? appPkg
  : cratePkg;

class Actor {
  constructor() {
    this.child = spawn(actorBinary, ['embedded'], {
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    this.pending = new Map();
    this.nextId = 1;
    this.ready = new Promise((resolveReady, rejectReady) => {
      this.resolveReady = resolveReady;
      this.child.once('exit', (code) =>
        rejectReady(new Error(`embedded actor exited before ready (${code})`)),
      );
    });
    this.ready.catch(() => {});
    createInterface({input: this.child.stdout}).on('line', (line) => {
      const message = JSON.parse(line);
      if (message.ready) {
        this.resolveReady(message);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.ok) pending.resolve(message);
      else pending.reject(new Error(message.error));
    });
  }

  command(cmd, fields = {}) {
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new Error(`actor command ${cmd} timed out`));
      }, 90_000);
      this.pending.set(id, {resolve: resolveCommand, reject: rejectCommand, timer});
      this.child.stdin.write(`${JSON.stringify({id, cmd, ...fields})}\n`);
    });
  }

  async stop() {
    await this.command('stop');
    const code = await new Promise((resolveExit) =>
      this.child.once('exit', resolveExit),
    );
    if (code !== 0) throw new Error(`embedded actor exited with code ${code}`);
  }

  kill() {
    this.child.kill('SIGKILL');
  }
}

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
  ['/pkg/manymatrix_web_bg.wasm', join(pkgDirectory, 'manymatrix_web_bg.wasm')],
]);
const mimeTypes = {
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
};
const server = createServer(async (request, response) => {
  if (request.url === '/') {
    response.writeHead(200, {'content-type': 'text/html; charset=utf-8'});
    response.end('<!doctype html><title>ManyMatrix ordinary E2E</title>');
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

async function call(page, client, method, args = {}) {
  const reply = await page.evaluate(
    (clientName, methodName, methodArgs) =>
      window.mmCall(clientName, methodName, methodArgs),
    client,
    method,
    args,
  );
  if (reply.err) {
    throw new Error(`${method}: ${JSON.stringify(reply.err)}`);
  }
  return reply.ok;
}

async function waitForEvent(page, client, kind, field, expected) {
  return page.evaluate(
    (clientName, eventKind, fieldName, expectedValue) =>
      window.mmWaitEvent(
        clientName,
        (event) =>
          event.kind === eventKind && event.payload[fieldName] === expectedValue,
      ),
    client,
    kind,
    field,
    expected,
  );
}

async function waitForInvite(page, client, roomId) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const result = await call(page, client, 'rooms.invited');
    const invites = JSON.parse(result.invites_json);
    if (invites.some((invite) => invite.room_id === roomId)) return invites;
    await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  }
  throw new Error(`timed out waiting for invitation ${roomId}`);
}

await new Promise((resolveListen) =>
  server.listen(0, '127.0.0.1', resolveListen),
);
const {port} = server.address();
let actor;
let browser;
try {
  actor = new Actor();
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
  await page.evaluate(() => {
    window.mmClients = new Map();
    window.mmStart = (name) =>
      new Promise((resolveStart, rejectStart) => {
        const worker = new Worker('/manymatrix_worker.js', {type: 'module'});
        const client = {
          worker,
          nextId: 1,
          pending: new Map(),
          events: [],
          closed: null,
        };
        client.closed = new Promise((resolveClosed) => {
          client.resolveClosed = resolveClosed;
        });
        window.mmClients.set(name, client);
        const timer = setTimeout(
          () => rejectStart(new Error(`${name} worker init timed out`)),
          30_000,
        );
        worker.onerror = (event) => {
          event.preventDefault();
          clearTimeout(timer);
          rejectStart(new Error(`${name} worker failed to load`));
        };
        worker.onmessage = (event) => {
          const message = event.data;
          if (message.type === 'manymatrix-ready') {
            clearTimeout(timer);
            resolveStart();
          } else if (message.type === 'manymatrix-event') {
            client.events.push({
              kind: message.kind,
              payload: JSON.parse(message.payload),
            });
          } else if (message.type === 'manymatrix-closed') {
            client.resolveClosed();
          } else if (client.pending.has(message.id)) {
            client.pending.get(message.id)(message);
            client.pending.delete(message.id);
          }
        };
      });
    window.mmCall = (name, method, args) => {
      const client = window.mmClients.get(name);
      const id = client.nextId++;
      return new Promise((resolveCall, rejectCall) => {
        const timer = setTimeout(
          () => rejectCall(new Error(`${name}:${method} timed out`)),
          60_000,
        );
        client.pending.set(id, (message) => {
          clearTimeout(timer);
          resolveCall(
            message.type === 'manymatrix-result'
              ? {ok: message.ok}
              : {err: message.error},
          );
        });
        client.worker.postMessage({
          type: 'manymatrix-call',
          id,
          method,
          args,
        });
      });
    };
    window.mmWaitEvent = (name, predicate) => {
      const client = window.mmClients.get(name);
      return new Promise((resolveEvent, rejectEvent) => {
        const deadline = Date.now() + 60_000;
        const poll = () => {
          const event = client.events.find(predicate);
          if (event) return resolveEvent(event);
          if (Date.now() >= deadline) {
            return rejectEvent(new Error(`${name} event timed out`));
          }
          setTimeout(poll, 25);
        };
        poll();
      });
    };
    window.mmClose = async (name) => {
      const client = window.mmClients.get(name);
      client.worker.postMessage({type: 'manymatrix-close'});
      await Promise.race([
        client.closed,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error(`${name} close timed out`)), 5_000),
        ),
      ]);
      client.worker.terminate();
    };
  });

  const info = await actor.ready;
  await page.evaluate(() => window.mmStart('account-a'));
  const storeA = `ordinary-a-${Date.now()}`;
  const loginA = await call(page, 'account-a', 'auth.login', {
    homeserver_url: info.base_url,
    username: info.ext_localpart,
    password: info.ext_password,
    store_name: storeA,
  });
  assert.equal(loginA.user_id, info.ext_user_id);
  assert.deepEqual(JSON.parse((await call(page, 'account-a', 'rooms.list')).rooms_json), []);
  const created = await call(page, 'account-a', 'rooms.create', {
    name: 'Ordinary browser room',
    invite: [info.actor_user_id],
    public: false,
  });
  const details = JSON.parse(
    (await call(page, 'account-a', 'rooms.details', {room_id: created.room_id}))
      .details_json,
  );
  assert.equal(details.room_id, created.room_id);
  await call(page, 'account-a', 'events.subscribe');
  await call(page, 'account-a', 'sync.start');
  await actor.command('join', {room_id: created.room_id});
  const incoming = await actor.command('send_text', {
    room_id: created.room_id,
    body: 'from embedded actor',
  });
  await waitForEvent(page, 'account-a', 'message', 'event_id', incoming.event_id);
  const outgoing = await call(page, 'account-a', 'messages.send_text', {
    room_id: created.room_id,
    body: 'from ordinary browser',
  });
  const threadReply = await actor.command('thread_reply', {
    room_id: created.room_id,
    thread_root_event_id: outgoing.event_id,
    body: 'thread reply from embedded actor',
  });
  const threadEvent = await waitForEvent(
    page,
    'account-a',
    'message',
    'event_id',
    threadReply.event_id,
  );
  assert.equal(threadEvent.payload.thread_root, outgoing.event_id);
  const threadIndex = JSON.parse(
    (
      await call(page, 'account-a', 'threads.index', {
        limit_per_room: 20,
      })
    ).threads_json,
  );
  const indexedThread = threadIndex.find(
    thread =>
      thread.room_id === created.room_id &&
      thread.root.event_id === outgoing.event_id,
  );
  assert.ok(indexedThread, 'web thread index should include actor reply');
  assert.equal(indexedThread.reply_count, 1);
  assert.equal(indexedThread.latest_reply?.event_id, threadReply.event_id);
  const threadPage = JSON.parse(
    (
      await call(page, 'account-a', 'threads.messages', {
        room_id: created.room_id,
        thread_root_event_id: outgoing.event_id,
        from_token: null,
        limit: 20,
      })
    ).paginated_json,
  );
  assert.equal(threadPage.root.event_id, outgoing.event_id);
  assert.deepEqual(
    threadPage.messages.map(message => message.event_id),
    [threadReply.event_id],
  );
  await call(page, 'account-a', 'threads.read_receipt', {
    room_id: created.room_id,
    thread_root_event_id: outgoing.event_id,
    event_id: threadReply.event_id,
  });
  await actor.command('react', {
    room_id: created.room_id,
    event_id: outgoing.event_id,
    key: '+1',
  });
  await waitForEvent(page, 'account-a', 'reaction', 'relates_to_event_id', outgoing.event_id);

  const mediaBytes = Buffer.from('ordinary browser media proof', 'utf8');
  const mediaUpload = await call(page, 'account-a', 'media.upload', {
    room_id: created.room_id,
    filename: 'proof.txt',
    mime_type: 'text/plain',
    data_base64: mediaBytes.toString('base64'),
  });
  const mediaEvent = await waitForEvent(
    page,
    'account-a',
    'message',
    'event_id',
    mediaUpload.event_id,
  );
  assert.equal(mediaEvent.payload.filename, 'proof.txt');
  assert.ok(
    mediaEvent.payload.file_size == null ||
      mediaEvent.payload.file_size === mediaBytes.length,
  );
  assert.match(mediaEvent.payload.mxc_uri, /^mxc:\/\//);
  const mediaDownload = await call(page, 'account-a', 'media.download', {
    mxc_uri: mediaEvent.payload.mxc_uri,
  });
  assert.deepEqual(
    Buffer.from(mediaDownload.data_base64, 'base64'),
    mediaBytes,
  );

  const encryptedRoom = await call(page, 'account-a', 'rooms.create', {
    name: 'Ordinary encrypted media room',
    invite: [],
    public: false,
  });
  await call(page, 'account-a', 'e2ee.enable', {
    room_id: encryptedRoom.room_id,
  });
  await new Promise((resolveWait) => setTimeout(resolveWait, 1_000));
  const encryptedBytes = Buffer.from(
    'ordinary browser encrypted media proof',
    'utf8',
  );
  const encryptedUpload = await call(page, 'account-a', 'media.upload', {
    room_id: encryptedRoom.room_id,
    filename: 'secret.txt',
    mime_type: 'text/plain',
    data_base64: encryptedBytes.toString('base64'),
  });
  const encryptedEvent = await waitForEvent(
    page,
    'account-a',
    'message',
    'event_id',
    encryptedUpload.event_id,
  );
  assert.equal(encryptedEvent.payload.mxc_uri, null);
  assert.ok(encryptedEvent.payload.media_source?.file);
  const encryptedDownload = await call(
    page,
    'account-a',
    'media.download',
    {media_source: encryptedEvent.payload.media_source},
  );
  assert.deepEqual(
    Buffer.from(encryptedDownload.data_base64, 'base64'),
    encryptedBytes,
  );

  const invitation = await actor.command('create_invite', {
    user_id: info.ext_user_id,
  });
  await waitForInvite(page, 'account-a', invitation.room_id);
  await call(page, 'account-a', 'rooms.join', {
    room_id_or_alias: invitation.room_id,
  });

  await page.evaluate(() => window.mmStart('account-b'));
  const storeB = `ordinary-b-${Date.now()}`;
  const loginB = await call(page, 'account-b', 'auth.login', {
    homeserver_url: info.base_url,
    username: info.second_localpart,
    password: info.second_password,
    store_name: storeB,
  });
  assert.equal(loginB.user_id, info.second_user_id);

  await page.evaluate(() => window.mmClose('account-a'));
  assert.equal(
    (await call(page, 'account-b', 'auth.whoami')).user_id,
    info.second_user_id,
  );

  await page.evaluate(() => window.mmStart('account-a-restored'));
  const restored = await call(page, 'account-a-restored', 'auth.restore', {
    homeserver_url: info.base_url,
    session_json: loginA.session_json,
    store_name: storeA,
  });
  assert.equal(restored.user_id, info.ext_user_id);
  const restoredRooms = JSON.parse(
    (await call(page, 'account-a-restored', 'rooms.list')).rooms_json,
  );
  assert.ok(restoredRooms.some((room) => room.room_id === created.room_id));
  await call(page, 'account-a-restored', 'events.subscribe');
  await call(page, 'account-a-restored', 'sync.start');
  const afterRestore = await actor.command('send_text', {
    room_id: created.room_id,
    body: 'after worker restore',
  });
  await waitForEvent(
    page,
    'account-a-restored',
    'message',
    'event_id',
    afterRestore.event_id,
  );

  await page.evaluate(async () => {
    await window.mmClose('account-a-restored');
    await window.mmClose('account-b');
  });
  // A sync request already accepted by the homeserver retains its server-side
  // handle until the dispatcher's 30-second long-poll deadline even after the
  // browser has terminated its Worker. Wait out that bounded request before
  // asking embedded Tuwunel to assert a clean shutdown.
  await new Promise((resolveWait) => setTimeout(resolveWait, 31_000));
  assert.deepEqual(browserErrors, []);
  await actor.stop();
  actor = null;
  console.log(
    'ordinary Matrix E2E passed: login, rooms, threads/index/receipt, invite, plain/encrypted media round-trips, send/receive, restore, isolation, teardown',
  );
} finally {
  actor?.kill();
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}
