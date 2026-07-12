export const LEGACY_SESSION_KEY = 'manymatrix_session';

const LEGACY_DATABASE_PATTERN = /^manymatrix_https?___/i;
const LEGACY_BACKUP_DATABASE_PATTERN = /^backup-manymatrix_https?___/i;

export function canonicalHomeserverUrl(value) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('legacy Matrix session has no homeserver URL');
  }
  const url = new URL(value);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('legacy Matrix homeserver must use HTTP or HTTPS');
  }
  if (url.username || url.password || url.search || url.hash || !url.hostname) {
    throw new Error('legacy Matrix homeserver URL is not canonical');
  }

  let path = url.pathname;
  while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  url.pathname = path === '/' ? '' : path;
  let canonical = url.toString();
  if (canonical.endsWith('/') && url.pathname === '/') {
    canonical = canonical.slice(0, -1);
  }
  return canonical;
}

export function legacyStoreNameFor(homeserverUrl) {
  const canonical = canonicalHomeserverUrl(homeserverUrl);
  return `manymatrix_${canonical.replace(/[^a-zA-Z0-9]/g, '_')}`;
}

function legacySessionHomeserver(sessionJson) {
  if (typeof sessionJson !== 'string') return null;
  try {
    const decoded = JSON.parse(sessionJson);
    return canonicalHomeserverUrl(decoded?.homeserver);
  } catch (_) {
    return null;
  }
}

function deterministicDatabaseNames(storeName) {
  return [
    storeName,
    `${storeName}::matrix-sdk-state`,
    `${storeName}::matrix-sdk-crypto`,
    `${storeName}::matrix-sdk-crypto-meta`,
  ];
}

function belongsToLegacyStore(name, storeNames) {
  if (LEGACY_DATABASE_PATTERN.test(name) ||
      LEGACY_BACKUP_DATABASE_PATTERN.test(name)) {
    return true;
  }
  for (const storeName of storeNames) {
    if (name === storeName ||
        name.startsWith(`${storeName}::`) ||
        name.startsWith(`backup-${storeName}-`)) {
      return true;
    }
  }
  return false;
}

function deleteDatabase(indexedDb, name) {
  return new Promise((resolve, reject) => {
    let request;
    try {
      request = indexedDb.deleteDatabase(name);
    } catch (error) {
      reject(error);
      return;
    }
    request.onsuccess = () => resolve();
    request.onerror = () => reject(
      request.error ?? new Error(`failed to delete legacy database ${name}`),
    );
    request.onblocked = () => reject(
      new Error(`legacy database ${name} is still open`),
    );
  });
}

export async function scrubLegacyExtensionStorage({
  storageLocal,
  indexedDb,
  expectedHomeserverUrl,
  scopedSessionKey,
}) {
  const failures = [];
  const storeNames = new Set();
  let legacySession;

  if (expectedHomeserverUrl != null) {
    try {
      storeNames.add(legacyStoreNameFor(expectedHomeserverUrl));
    } catch (error) {
      failures.push(error);
    }
  }

  try {
    const stored = await storageLocal.get(LEGACY_SESSION_KEY);
    legacySession = stored?.[LEGACY_SESSION_KEY];
    const storedHomeserver = legacySessionHomeserver(legacySession);
    if (storedHomeserver != null) {
      storeNames.add(legacyStoreNameFor(storedHomeserver));
    }
  } catch (error) {
    failures.push(error);
  }

  const keys = scopedSessionKey == null
    ? LEGACY_SESSION_KEY
    : [LEGACY_SESSION_KEY, scopedSessionKey];
  try {
    // Remove the bearer token before database cleanup. A later failure must
    // never leave the globally scoped secret available to another account.
    await storageLocal.remove(keys);
  } catch (error) {
    failures.push(error);
  }

  const databaseNames = new Set();
  for (const storeName of storeNames) {
    for (const name of deterministicDatabaseNames(storeName)) {
      databaseNames.add(name);
    }
  }
  try {
    // A previous extension version could remove its token without deleting
    // its databases. Always enumerate, but admit only the old URL-derived
    // namespace or an explicitly derived expected namespace.
    const databases = await indexedDb.databases();
    for (const database of databases ?? []) {
      const name = typeof database === 'string' ? database : database?.name;
      if (typeof name === 'string' &&
          belongsToLegacyStore(name, storeNames)) {
        databaseNames.add(name);
      }
    }
  } catch (error) {
    failures.push(error);
  }

  for (const name of databaseNames) {
    try {
      await deleteDatabase(indexedDb, name);
    } catch (error) {
      failures.push(error);
    }
  }

  if (failures.length !== 0) {
    throw new AggregateError(
      failures,
      'legacy ManyMatrix extension state could not be fully removed',
    );
  }
  return {
    legacySessionFound: legacySession != null,
    deletedDatabases: [...databaseNames].sort(),
  };
}

export class LegacyExtensionStorageScrubber {
  constructor({storageLocal, indexedDb}) {
    this.storageLocal = storageLocal;
    this.indexedDb = indexedDb;
    this.pendingEnsure = null;
    this.ensureResult = null;
  }

  ensure(options = {}) {
    if (this.ensureResult != null) return Promise.resolve(this.ensureResult);
    if (this.pendingEnsure != null) return this.pendingEnsure;

    const operation = this.scrub(options);
    this.pendingEnsure = operation;
    operation.then(
      (result) => {
        if (this.pendingEnsure === operation) {
          this.pendingEnsure = null;
          this.ensureResult = result;
        }
      },
      () => {
        if (this.pendingEnsure === operation) this.pendingEnsure = null;
      },
    );
    return operation;
  }

  scrub(options = {}) {
    return scrubLegacyExtensionStorage({
      storageLocal: this.storageLocal,
      indexedDb: this.indexedDb,
      ...options,
    });
  }
}
