export function rpcTimeoutMs(method) {
  return typeof method === 'string' && method.startsWith('media.')
    ? 5 * 60_000
    : 30_000;
}

export async function closeClientWorker(
  worker,
  closed,
  {
    timeoutMs = 2_000,
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  } = {},
) {
  try {
    worker.postMessage({type: 'manymatrix-close'});
  } catch (_) {
    worker.terminate();
    return false;
  }

  let closedGracefully = false;
  await Promise.race([
    Promise.resolve(closed).then(() => {
      closedGracefully = true;
    }),
    sleep(timeoutMs),
  ]);
  worker.terminate();
  return closedGracefully;
}

export class OffscreenDocumentManager {
  constructor({
    hasDocument,
    createDocument,
    closeDocument,
    probeReady,
    existingProbeTimeoutMs = 500,
    startupTimeoutMs = 5_000,
    probeIntervalMs = 25,
    now = () => Date.now(),
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  }) {
    this.hasDocument = hasDocument;
    this.createDocument = createDocument;
    this.closeDocument = closeDocument;
    this.probeReady = probeReady;
    this.existingProbeTimeoutMs = existingProbeTimeoutMs;
    this.startupTimeoutMs = startupTimeoutMs;
    this.probeIntervalMs = probeIntervalMs;
    this.now = now;
    this.sleep = sleep;
    this.pendingEnsure = null;
  }

  ensure() {
    if (this.pendingEnsure) return this.pendingEnsure;
    const operation = this.#ensure();
    this.pendingEnsure = operation;
    operation.then(
      () => {
        if (this.pendingEnsure === operation) this.pendingEnsure = null;
      },
      () => {
        if (this.pendingEnsure === operation) this.pendingEnsure = null;
      },
    );
    return operation;
  }

  async #ensure() {
    let replaced = false;
    if (await this.hasDocument()) {
      if (await this.#waitUntilReady(this.existingProbeTimeoutMs)) {
        return {created: false, replaced: false};
      }
      await this.#closeIfPresent();
      replaced = true;
    }

    try {
      await this.createDocument();
    } catch (error) {
      // Another ensure may have won outside this service-worker instance.
      // Accept that document only after it answers the health handshake.
      if (await this.hasDocument() &&
          await this.#waitUntilReady(this.existingProbeTimeoutMs)) {
        return {created: false, replaced};
      }
      await this.#closeIfPresent();
      throw error;
    }

    if (await this.#waitUntilReady(this.startupTimeoutMs)) {
      return {created: true, replaced};
    }

    // Do not leave a document whose module failed to install its listener.
    // The next envelope can make a clean creation attempt.
    await this.#closeIfPresent();
    throw new Error('offscreen document did not answer its readiness probe');
  }

  async #closeIfPresent() {
    if (!await this.hasDocument()) return;
    try {
      await this.closeDocument();
    } catch (error) {
      // Chrome can discard an offscreen document between the presence check
      // and closeDocument(). Only preserve errors for a document still there.
      if (await this.hasDocument()) throw error;
    }
  }

  async #waitUntilReady(timeoutMs) {
    const deadline = this.now() + timeoutMs;
    do {
      try {
        if (await this.probeReady()) return true;
      } catch (_) {
        // A missing receiver is the expected result while the module loads.
      }
      if (this.now() >= deadline) return false;
      await this.sleep(Math.min(this.probeIntervalMs, deadline - this.now()));
    } while (this.now() <= deadline);
    return false;
  }
}

export class OwnedClientRegistry {
  constructor(
    createClient,
    {leaseMs = 2_500, now = () => Date.now()} = {},
  ) {
    this.createClient = createClient;
    this.leaseMs = leaseMs;
    this.now = now;
    this.entries = new Map();
    this.operations = new Map();
  }

  claim(clientId, ownerId, {recovering = false} = {}) {
    return this.#serialize(clientId, () =>
      this.#claim(clientId, ownerId, recovering));
  }

  async #claim(clientId, ownerId, recovering) {
    const existing = this.entries.get(clientId);
    if (existing?.closing) {
      await existing.closing;
      return this.#claim(clientId, ownerId, recovering);
    }
    if (existing?.ownerId === ownerId) {
      existing.lastSeen = this.now();
      return existing.ready;
    }
    if (existing && this.now() - existing.lastSeen <= this.leaseMs) {
      throw ownerActiveError(clientId);
    }
    if (existing) {
      await this.#closeEntry(clientId, existing);
      return this.#claim(clientId, ownerId, recovering);
    }

    const entry = {
      ownerId,
      lastSeen: this.now(),
      recovering,
      closing: null,
      ready: Promise.resolve().then(() => this.createClient(clientId, ownerId)),
    };
    this.entries.set(clientId, entry);
    try {
      return await entry.ready;
    } catch (error) {
      if (this.entries.get(clientId) === entry) this.entries.delete(clientId);
      throw error;
    }
  }

  async current(clientId, ownerId, {allowRecovering = false} = {}) {
    const entry = this.entries.get(clientId);
    if (!entry || entry.closing || entry.ownerId !== ownerId) {
      throw staleOwnerError(clientId);
    }
    if (entry.recovering && !allowRecovering) {
      throw recoveryPendingError(clientId);
    }
    entry.lastSeen = this.now();
    return entry.ready;
  }

  heartbeat(clientId, ownerId) {
    const entry = this.entries.get(clientId);
    if (!entry || entry.closing || entry.ownerId !== ownerId) {
      throw staleOwnerError(clientId);
    }
    entry.lastSeen = this.now();
  }

  recoveryComplete(clientId, ownerId) {
    const entry = this.entries.get(clientId);
    if (!entry || entry.closing || entry.ownerId !== ownerId) {
      throw staleOwnerError(clientId);
    }
    entry.recovering = false;
    entry.lastSeen = this.now();
  }

  dispose(clientId, ownerId) {
    return this.#serialize(clientId, () => this.#dispose(clientId, ownerId));
  }

  async #dispose(clientId, ownerId) {
    const entry = this.entries.get(clientId);
    if (!entry || entry.ownerId !== ownerId) return false;
    await this.#closeEntry(clientId, entry);
    return true;
  }

  #serialize(clientId, operation) {
    const previous = this.operations.get(clientId) ?? Promise.resolve();
    const result = previous.catch(() => {}).then(operation);
    const tail = result.then(() => {}, () => {});
    this.operations.set(clientId, tail);
    tail.then(() => {
      if (this.operations.get(clientId) === tail) this.operations.delete(clientId);
    });
    return result;
  }

  #closeEntry(clientId, entry) {
    if (entry.closing) return entry.closing;
    entry.closing = (async () => {
      try {
        const client = await entry.ready;
        await client.dispose();
      } finally {
        if (this.entries.get(clientId) === entry) {
          this.entries.delete(clientId);
        }
      }
    })();
    return entry.closing;
  }
}

function ownerActiveError(clientId) {
  const error = new Error('This Matrix account is active in another extension view.');
  error.kind = 'StorageError';
  error.details = {reason: 'owner_active', client_id: clientId};
  return error;
}

function staleOwnerError(clientId) {
  const error = new Error('This extension view no longer owns the Matrix account runtime.');
  error.kind = 'StorageError';
  error.details = {reason: 'stale_owner', client_id: clientId};
  return error;
}

function recoveryPendingError(clientId) {
  const error = new Error('This Matrix account Worker is restoring its session.');
  error.kind = 'StorageError';
  error.details = {reason: 'recovery_pending', client_id: clientId};
  return error;
}
