import assert from 'node:assert/strict';
import test from 'node:test';

import {
  closeClientWorker,
  OffscreenDocumentManager,
  OwnedClientRegistry,
  rpcTimeoutMs,
} from '../../../flutter_plugin/example/extension/worker_lifecycle.mjs';

function fakeWorker() {
  return {
    messages: [],
    terminated: false,
    postMessage(message) {
      this.messages.push(message);
    },
    terminate() {
      this.terminated = true;
    },
  };
}

test('dispose remains pending until the Worker acknowledges close', async () => {
  const worker = fakeWorker();
  let resolveClosed;
  const closed = new Promise((resolve) => {
    resolveClosed = resolve;
  });
  let completed = false;

  const disposing = closeClientWorker(worker, closed, {
    sleep: () => new Promise(() => {}),
  }).then((graceful) => {
    completed = true;
    return graceful;
  });
  await Promise.resolve();

  assert.deepEqual(worker.messages, [{type: 'manymatrix-close'}]);
  assert.equal(worker.terminated, false);
  assert.equal(completed, false);

  resolveClosed();
  assert.equal(await disposing, true);
  assert.equal(worker.terminated, true);
});

test('dispose forcibly terminates before resolving when close times out', async () => {
  const worker = fakeWorker();
  const graceful = await closeClientWorker(worker, new Promise(() => {}), {
    sleep: async () => {},
  });

  assert.equal(graceful, false);
  assert.equal(worker.terminated, true);
});

test('media RPCs share a five-minute transport deadline', () => {
  assert.equal(rpcTimeoutMs('media.upload'), 5 * 60_000);
  assert.equal(rpcTimeoutMs('media.download'), 5 * 60_000);
  assert.equal(rpcTimeoutMs('media.download_source'), 5 * 60_000);
  assert.equal(rpcTimeoutMs('rooms.list'), 30_000);
});

test('offscreen readiness cannot be lost when creation is immediately ready', async () => {
  let documentExists = false;
  let ready = false;
  let createCount = 0;
  const manager = new OffscreenDocumentManager({
    hasDocument: async () => documentExists,
    createDocument: async () => {
      createCount += 1;
      documentExists = true;
      ready = true;
    },
    closeDocument: async () => {
      documentExists = false;
      ready = false;
    },
    probeReady: async () => ready,
  });

  assert.deepEqual(await manager.ensure(), {created: true, replaced: false});
  assert.equal(createCount, 1);
});

test('an existing failed offscreen document is closed and recreated', async () => {
  let now = 0;
  let documentExists = true;
  let ready = false;
  let createCount = 0;
  let closeCount = 0;
  const manager = new OffscreenDocumentManager({
    hasDocument: async () => documentExists,
    createDocument: async () => {
      createCount += 1;
      documentExists = true;
      ready = true;
    },
    closeDocument: async () => {
      closeCount += 1;
      documentExists = false;
      ready = false;
    },
    probeReady: async () => ready,
    existingProbeTimeoutMs: 10,
    probeIntervalMs: 5,
    now: () => now,
    sleep: async (milliseconds) => {
      now += milliseconds;
    },
  });

  assert.deepEqual(await manager.ensure(), {created: true, replaced: true});
  assert.equal(closeCount, 1);
  assert.equal(createCount, 1);
});

test('concurrent readiness checks share one offscreen creation', async () => {
  let documentExists = false;
  let ready = false;
  let createCount = 0;
  let finishCreate;
  const creating = new Promise((resolve) => {
    finishCreate = resolve;
  });
  const manager = new OffscreenDocumentManager({
    hasDocument: async () => documentExists,
    createDocument: async () => {
      createCount += 1;
      await creating;
      documentExists = true;
      ready = true;
    },
    closeDocument: async () => {
      documentExists = false;
      ready = false;
    },
    probeReady: async () => ready,
  });

  const first = manager.ensure();
  const second = manager.ensure();
  assert.equal(first, second);
  finishCreate();

  assert.deepEqual(await first, {created: true, replaced: false});
  assert.equal(createCount, 1);
});

test('a new page owner drains the previous account Worker before replacement', async () => {
  let now = 0;
  let releaseOld;
  const oldClose = new Promise((resolve) => {
    releaseOld = resolve;
  });
  const created = [];
  const registry = new OwnedClientRegistry((clientId, ownerId) => {
    const client = {
      clientId,
      ownerId,
      disposed: false,
      async dispose() {
        if (ownerId === 'old-page') await oldClose;
        this.disposed = true;
      },
    };
    created.push(client);
    return client;
  }, {leaseMs: 10, now: () => now});

  const oldClient = await registry.claim('account-store', 'old-page');
  await assert.rejects(
    registry.claim('account-store', 'new-page'),
    (error) => error.details?.reason === 'owner_active',
  );
  now = 11;
  const replacing = registry.claim('account-store', 'new-page');
  await Promise.resolve();

  assert.equal(created.length, 1);
  assert.equal(oldClient.disposed, false);

  releaseOld();
  const newClient = await replacing;
  assert.equal(oldClient.disposed, true);
  assert.equal(created.length, 2);
  assert.equal(newClient.ownerId, 'new-page');

  assert.equal(await registry.dispose('account-store', 'old-page'), false);
  assert.equal(newClient.disposed, false);
  assert.equal(await registry.dispose('account-store', 'new-page'), true);
  assert.equal(newClient.disposed, true);
});

test('a claim waits behind the closing tombstone', async () => {
  let releaseClose;
  const closeGate = new Promise((resolve) => {
    releaseClose = resolve;
  });
  const created = [];
  const registry = new OwnedClientRegistry((clientId, ownerId) => {
    const client = {
      ownerId,
      async dispose() {
        await closeGate;
      },
    };
    created.push(client);
    return client;
  });
  await registry.claim('account-store', 'old-page');

  const disposing = registry.dispose('account-store', 'old-page');
  await Promise.resolve();
  const claiming = registry.claim('account-store', 'new-page');
  await Promise.resolve();
  assert.equal(created.length, 1);

  releaseClose();
  await disposing;
  const replacement = await claiming;
  assert.equal(created.length, 2);
  assert.equal(replacement.ownerId, 'new-page');
});

test('a synchronous client creation failure leaves the account retryable', async () => {
  let attempts = 0;
  const registry = new OwnedClientRegistry(() => {
    attempts += 1;
    if (attempts === 1) throw new Error('worker construction failed');
    return {async dispose() {}};
  });

  await assert.rejects(
    registry.claim('account-store', 'page'),
    /worker construction failed/,
  );
  const client = await registry.claim('account-store', 'page');

  assert.ok(client);
  assert.equal(attempts, 2);
});

test('replacement blocks normal RPCs until recovery completes', async () => {
  const registry = new OwnedClientRegistry(
    (_clientId, ownerId) => ({ownerId, async dispose() {}}),
  );

  await registry.claim('account-store', 'page', {recovering: true});
  await assert.rejects(
    registry.current('account-store', 'page'),
    (error) => error.details?.reason === 'recovery_pending',
  );
  const recovering = await registry.current('account-store', 'page', {
    allowRecovering: true,
  });
  assert.equal(recovering.ownerId, 'page');

  registry.recoveryComplete('account-store', 'page');
  assert.equal(
    (await registry.current('account-store', 'page')).ownerId,
    'page',
  );
});

test('unauthenticated replacement completes recovery without restore calls', async () => {
  const registry = new OwnedClientRegistry(
    (_clientId, ownerId) => ({ownerId, calls: [], async dispose() {}}),
  );

  await registry.claim('account-store', 'page', {recovering: true});
  registry.recoveryComplete('account-store', 'page');

  const client = await registry.current('account-store', 'page');
  assert.equal(client.ownerId, 'page');
  assert.deepEqual(client.calls, []);
});

test('dispose queued behind replacement closes the newly claimed Worker', async () => {
  let now = 0;
  let releaseOld;
  const oldClosing = new Promise((resolve) => {
    releaseOld = resolve;
  });
  const created = [];
  const registry = new OwnedClientRegistry((_clientId, ownerId) => {
    const client = {
      ownerId,
      disposed: false,
      async dispose() {
        if (ownerId === 'old') await oldClosing;
        this.disposed = true;
      },
    };
    created.push(client);
    return client;
  }, {leaseMs: 1, now: () => now});
  await registry.claim('account-store', 'old');
  now = 2;

  const replacing = registry.claim('account-store', 'new', {recovering: true});
  const disposing = registry.dispose('account-store', 'new');
  await Promise.resolve();
  assert.equal(created.length, 1);

  releaseOld();
  await replacing;
  assert.equal(await disposing, true);
  assert.equal(created.length, 2);
  assert.equal(created[1].disposed, true);
});
