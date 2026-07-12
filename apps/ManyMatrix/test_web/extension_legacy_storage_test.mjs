import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

import {
  LEGACY_SESSION_KEY,
  LegacyExtensionStorageScrubber,
  legacyStoreNameFor,
  scrubLegacyExtensionStorage,
} from '../../../flutter_plugin/example/extension/legacy_storage.mjs';

function fakeStorage(initial) {
  const values = {...initial};
  return {
    values,
    getCount: 0,
    removed: [],
    async get(key) {
      this.getCount += 1;
      return {[key]: values[key]};
    },
    async remove(keys) {
      const list = Array.isArray(keys) ? keys : [keys];
      this.removed.push(...list);
      for (const key of list) delete values[key];
    },
  };
}

function fakeIndexedDb(names, {beforeEnumerate, failDelete} = {}) {
  return {
    deleted: [],
    async databases() {
      await beforeEnumerate?.();
      return names.map((name) => ({name}));
    },
    deleteDatabase(name) {
      this.deleted.push(name);
      const request = {};
      queueMicrotask(() => {
        if (failDelete?.(name)) {
          request.onblocked?.();
        } else {
          request.onsuccess?.();
        }
      });
      return request;
    },
  };
}

test('startup scrub removes a legacy token and every legacy database namespace', async () => {
  const expectedHomeserver = 'https://current.example';
  const storedHomeserver = 'https://old.example/matrix/';
  const expectedStore = legacyStoreNameFor(expectedHomeserver);
  const storedStore = legacyStoreNameFor(storedHomeserver);
  const unrelatedLegacyStore = legacyStoreNameFor('http://other.example:8080');
  const scopedStore = 'manymatrix_account_store_current.example';
  const uppercaseLegacyStore = 'manymatrix_HTTPS___UPPER_example';
  const storage = fakeStorage({
    [LEGACY_SESSION_KEY]: JSON.stringify({
      homeserver: storedHomeserver,
      access_token: 'legacy-secret',
    }),
    manymatrix_session_scoped: 'current-secret',
  });
  const indexedDb = fakeIndexedDb([
    `${storedStore}::matrix-sdk-crypto`,
    `backup-${storedStore}-backup-id`,
    `${unrelatedLegacyStore}::matrix-sdk-state`,
    `${uppercaseLegacyStore}::matrix-sdk-crypto`,
    `backup-${uppercaseLegacyStore}-backup-id`,
    scopedStore,
  ]);

  const result = await scrubLegacyExtensionStorage({
    storageLocal: storage,
    indexedDb,
    expectedHomeserverUrl: expectedHomeserver,
  });

  assert.equal(result.legacySessionFound, true);
  assert.equal(storage.values[LEGACY_SESSION_KEY], undefined);
  assert.equal(storage.values.manymatrix_session_scoped, 'current-secret');
  assert.ok(indexedDb.deleted.includes(expectedStore));
  assert.ok(indexedDb.deleted.includes(`${storedStore}::matrix-sdk-crypto`));
  assert.ok(indexedDb.deleted.includes(`backup-${storedStore}-backup-id`));
  assert.equal(indexedDb.deleted.includes(
    `${unrelatedLegacyStore}::matrix-sdk-state`,
  ), true);
  assert.ok(indexedDb.deleted.includes(
    `${uppercaseLegacyStore}::matrix-sdk-crypto`,
  ));
  assert.ok(indexedDb.deleted.includes(
    `backup-${uppercaseLegacyStore}-backup-id`,
  ));
  assert.equal(indexedDb.deleted.includes(scopedStore), false);
});

test('malformed legacy state scrubs secrets and recognizable legacy databases', async () => {
  const discoveredStore = legacyStoreNameFor('https://orphan.example');
  const storage = fakeStorage({
    [LEGACY_SESSION_KEY]: '{malformed',
    scoped_key: 'scoped-secret',
  });
  const indexedDb = fakeIndexedDb([
    `${discoveredStore}::matrix-sdk-crypto-meta`,
    `backup-${discoveredStore}-backup-id`,
  ]);

  await scrubLegacyExtensionStorage({
    storageLocal: storage,
    indexedDb,
    scopedSessionKey: 'scoped_key',
  });

  assert.deepEqual(storage.values, {});
  assert.ok(indexedDb.deleted.includes(
    `${discoveredStore}::matrix-sdk-crypto-meta`,
  ));
  assert.ok(indexedDb.deleted.includes(
    `backup-${discoveredStore}-backup-id`,
  ));
});

test('startup scrub deletes tokenless legacy databases without touching scoped stores', async () => {
  const orphanStore = 'manymatrix_HTTP___ORPHAN_example';
  const scopedStore = 'manymatrix_manymatrix-web-store-account_example.org';
  const storage = fakeStorage({});
  const indexedDb = fakeIndexedDb([
    `${orphanStore}::matrix-sdk-state`,
    `backup-${orphanStore}-backup-id`,
    scopedStore,
  ]);

  const scrubber = new LegacyExtensionStorageScrubber({
    storageLocal: storage,
    indexedDb,
  });
  const result = await scrubber.ensure();

  assert.equal(result.legacySessionFound, false);
  assert.ok(indexedDb.deleted.includes(`${orphanStore}::matrix-sdk-state`));
  assert.ok(indexedDb.deleted.includes(`backup-${orphanStore}-backup-id`));
  assert.equal(indexedDb.deleted.includes(scopedStore), false);
});

test('concurrent startup checks share one fail-closed scrub', async () => {
  let releaseEnumeration;
  const enumerationGate = new Promise((resolve) => {
    releaseEnumeration = resolve;
  });
  const storage = fakeStorage({});
  const indexedDb = fakeIndexedDb([], {
    beforeEnumerate: () => enumerationGate,
  });
  const scrubber = new LegacyExtensionStorageScrubber({
    storageLocal: storage,
    indexedDb,
  });

  const first = scrubber.ensure();
  const second = scrubber.ensure();
  assert.equal(first, second);
  assert.equal(storage.getCount, 1);

  releaseEnumeration();
  const result = await first;
  assert.deepEqual(await scrubber.ensure(), result);
  assert.equal(storage.getCount, 1);
});

test('database cleanup failure remains fail-closed after token removal', async () => {
  const homeserver = 'https://blocked.example';
  const storeName = legacyStoreNameFor(homeserver);
  const storage = fakeStorage({
    [LEGACY_SESSION_KEY]: JSON.stringify({
      homeserver,
      access_token: 'legacy-secret',
    }),
  });
  const indexedDb = fakeIndexedDb([storeName], {
    failDelete: (name) => name === storeName,
  });

  await assert.rejects(
    scrubLegacyExtensionStorage({storageLocal: storage, indexedDb}),
    (error) => error instanceof AggregateError,
  );
  assert.equal(storage.values[LEGACY_SESSION_KEY], undefined);
  assert.ok(indexedDb.deleted.includes(storeName));
  assert.ok(indexedDb.deleted.includes(`${storeName}::matrix-sdk-crypto`));
});

test('legacy scrub is extension-only and privileged pages are not web-accessible', async () => {
  const [manifestSource, serviceWorker, ordinaryWorker, ordinaryProtocol] =
    await Promise.all([
      readFile('flutter_plugin/example/extension/manifest.json', 'utf8'),
      readFile('flutter_plugin/example/extension/sw.js', 'utf8'),
      readFile('apps/ManyMatrix/web/manymatrix_worker.js', 'utf8'),
      readFile('apps/ManyMatrix/web/manymatrix_worker_protocol.mjs', 'utf8'),
    ]);
  const manifest = JSON.parse(manifestSource);

  assert.equal('web_accessible_resources' in manifest, false);
  assert.match(serviceWorker, /from '.\/legacy_storage\.mjs'/);
  assert.match(serviceWorker, /legacyStorage\.ensure\(\)\.catch/);
  assert.match(serviceWorker, /legacyStorage\.ensure\(\)[\s\S]*ensureOffscreenDocument/);
  assert.doesNotMatch(ordinaryWorker, /legacy_storage|manymatrix-legacy-storage/);
  assert.doesNotMatch(ordinaryProtocol, /legacy_storage|manymatrix-legacy-storage/);
});
