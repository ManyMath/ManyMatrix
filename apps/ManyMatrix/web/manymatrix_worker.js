let wasmCall;
let protocol;

self.onmessage = async (event) => {
  // Disposal can race module initialization, so recognize close without
  // dereferencing the asynchronously imported protocol module.
  if (event.data?.type === 'manymatrix-close') {
    try {
      if (wasmCall) await wasmCall('sync.stop', '{}');
    } finally {
      self.postMessage(
        protocol?.closedMessage?.() ?? {type: 'manymatrix-closed'},
      );
      self.close();
    }
    return;
  }

  let request;
  try {
    request = protocol.parseCallRequest(event.data);
  } catch (error) {
    const id = Number.isSafeInteger(event.data?.id) ? event.data.id : 0;
    self.postMessage(protocol.errorMessage(id, error));
    return;
  }

  const observeCall =
    request.method.startsWith('messages.') ||
    request.method === 'media.upload' ||
    request.method === 'events.subscribe' ||
    request.method === 'sync.start' ||
    request.method === 'sync.stop';
  const startedAt = performance.now();
  if (observeCall) {
    console.info(
      `[manymatrix-worker] ${request.method} #${request.id} started`,
    );
  }
  try {
    const replyJson = await wasmCall(
      request.method,
      JSON.stringify(request.args),
    );
    const reply = JSON.parse(replyJson);
    let status;
    if (reply?.ok !== undefined) {
      status = 'ok';
      self.postMessage(protocol.resultMessage(request.id, reply.ok));
    } else if (reply?.err !== undefined) {
      status = 'error';
      self.postMessage(protocol.errorMessage(request.id, reply.err));
    } else {
      status = 'malformed';
      self.postMessage(protocol.errorMessage(request.id, {
        kind: 'SerdeError',
        message: 'malformed WASM reply: missing ok/err',
        details: {},
      }));
    }
    if (observeCall) {
      console.info(
        `[manymatrix-worker] ${request.method} #${request.id} ` +
          `status=${status} duration_ms=${Math.round(performance.now() - startedAt)}`,
      );
    }
  } catch (error) {
    if (observeCall) {
      console.info(
        `[manymatrix-worker] ${request.method} #${request.id} ` +
          `status=threw duration_ms=${Math.round(performance.now() - startedAt)}`,
      );
    }
    self.postMessage(protocol.errorMessage(request.id, error));
  }
};

async function initialize() {
  try {
    protocol = await import('./manymatrix_worker_protocol.mjs');
    const module = await import('./pkg/manymatrix_web.js');
    await module.default();
    wasmCall = module.call;
    module.set_event_sink((kind, payload) => {
      if (kind === 'sync_status') {
        let status = 'invalid';
        let ok = false;
        try {
          const parsed = JSON.parse(payload);
          status = String(parsed.state ?? 'unknown');
          ok = parsed.ok === true;
        } catch (_) {
          // The event is still forwarded so Dart reports the malformed payload.
        }
        console.info(`[manymatrix-worker] sync_status state=${status} ok=${ok}`);
      }
      self.postMessage({type: protocol.messageTypes.event, kind, payload});
    });
    self.postMessage({type: protocol.messageTypes.ready});
  } catch (error) {
    const initError = protocol?.initErrorMessage ?? ((failure) => ({
      type: 'manymatrix-init-error',
      error: failure,
    }));
    self.postMessage(initError({
      kind: 'StorageError',
      message:
        'Could not initialize the ManyMatrix WASM runtime. Verify that the ' +
        'complete web build is deployed and that .wasm files use the ' +
        'application/wasm MIME type.',
      details: {cause: error instanceof Error ? error.message : String(error)},
    }));
  }
}

initialize();
