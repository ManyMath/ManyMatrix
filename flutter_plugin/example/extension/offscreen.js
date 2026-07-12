import {
  closeClientWorker,
  OwnedClientRegistry,
  rpcTimeoutMs,
} from './worker_lifecycle.mjs';

const clients = new OwnedClientRegistry(
  (clientId, ownerId) => new ClientWorker(clientId, ownerId),
);

class ClientWorker {
  constructor(clientId, ownerId) {
    this.clientId = clientId;
    this.ownerId = ownerId;
    this.nextRequestId = 1;
    this.pending = new Map();
    this.worker = new Worker('./manymatrix_worker.js', {
      type: 'module',
      name: `manymatrix-extension-${clientId}`,
    });
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.closed = new Promise((resolve) => {
      this.resolveClosed = resolve;
    });
    // A caller awaits ready before sending work; keep an early module-load
    // failure from surfacing as an unhandled rejection in the meantime.
    this.ready.catch(() => {});
    this.worker.onmessage = (event) => this.onMessage(event.data);
    this.worker.onerror = (event) => {
      event.preventDefault();
      this.fail(new Error('ManyMatrix extension worker failed to load'));
    };
    this.worker.onmessageerror = () => {
      this.fail(new Error('ManyMatrix extension worker sent an invalid message'));
    };
  }

  onMessage(message) {
    if (message?.type === 'manymatrix-ready') {
      this.resolveReady();
      return;
    }
    if (message?.type === 'manymatrix-init-error') {
      this.fail(envelopeError(message.error));
      return;
    }
    if (message?.type === 'manymatrix-event') {
      chrome.runtime.sendMessage({
        type: 'manymatrix-event',
        client_id: this.clientId,
        owner_id: this.ownerId,
        kind: message.kind,
        payload: message.payload,
      }).catch(() => {});
      return;
    }
    if (message?.type === 'manymatrix-closed') {
      this.resolveClosed();
      return;
    }

    const pending = this.pending.get(message?.id);
    if (!pending) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.type === 'manymatrix-result') {
      pending.resolve({ok: message.ok});
    } else if (message.type === 'manymatrix-error') {
      pending.resolve({err: message.error});
    } else {
      pending.resolve({
        err: {
          kind: 'SerdeError',
          message: 'unknown ManyMatrix worker response',
          details: {},
        },
      });
    }
  }

  fail(error) {
    this.rejectReady(error);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.resolve({err: errorEnvelope(error)});
    }
    this.pending.clear();
  }

  async call(method, args) {
    await this.ready;
    const id = this.nextRequestId++;
    return new Promise((resolve) => {
      const timeoutMs = rpcTimeoutMs(method);
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({
          err: {
            kind: 'StorageError',
            message: `ManyMatrix extension worker did not answer in ${timeoutMs / 1000} seconds`,
            details: {method},
          },
        });
      }, timeoutMs);
      this.pending.set(id, {resolve, timer});
      this.worker.postMessage({
        type: 'manymatrix-call',
        id,
        method,
        args: args ?? {},
      });
    });
  }

  dispose() {
    if (this.disposePromise) return this.disposePromise;
    this.fail(new Error('ManyMatrix client was disposed'));
    this.disposePromise = closeClientWorker(this.worker, this.closed);
    return this.disposePromise;
  }
}

function envelopeError(value) {
  const error = new Error(value?.message ?? 'ManyMatrix worker failed');
  error.kind = value?.kind;
  error.details = value?.details;
  return error;
}

function errorEnvelope(error) {
  return {
    kind: error?.kind ?? 'StorageError',
    message: error?.message ?? String(error),
    details: error?.details ?? {},
  };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.target === 'offscreen-health') {
    sendResponse({type: 'offscreen-health-ack', ready: true});
    return;
  }
  if (message?.target !== 'offscreen-call') return;
  const envelope = message.envelope ?? {};
  // Keep the low-level extension E2E driver backward-compatible while Dart
  // clients provide a stable account id plus a fresh page-owner id.
  const clientId = envelope.client_id ?? 'legacy-e2e-client';
  const ownerId = envelope.owner_id ?? `${clientId}:legacy-owner`;
  if (envelope.method === 'bridge.claim') {
    clients.claim(clientId, ownerId, {
      recovering: envelope.args?.recovering === true,
    })
      .then(() => sendResponse({ok: {}}))
      .catch((error) => sendResponse({err: errorEnvelope(error)}));
    return true;
  }
  if (envelope.method === 'bridge.heartbeat') {
    try {
      clients.heartbeat(clientId, ownerId);
      sendResponse({ok: {}});
    } catch (error) {
      sendResponse({err: errorEnvelope(error)});
    }
    return;
  }
  if (envelope.method === 'bridge.dispose') {
    clients.dispose(clientId, ownerId)
      .then(() => sendResponse({ok: {}}))
      .catch((error) => sendResponse({err: errorEnvelope(error)}));
    return true;
  }
  if (envelope.method === 'bridge.recovery_call') {
    clients.current(clientId, ownerId, {allowRecovering: true})
      .then((client) => client.call(
        envelope.args?.method,
        envelope.args?.args,
      ))
      .then(sendResponse)
      .catch((error) => sendResponse({err: errorEnvelope(error)}));
    return true;
  }
  if (envelope.method === 'bridge.recovery_complete') {
    try {
      clients.recoveryComplete(clientId, ownerId);
      sendResponse({ok: {}});
    } catch (error) {
      sendResponse({err: errorEnvelope(error)});
    }
    return;
  }

  clients.current(clientId, ownerId)
    .then((client) => client.call(envelope.method, envelope.args))
    .then(sendResponse)
    .catch((error) => sendResponse({err: errorEnvelope(error)}));
  return true;
});
