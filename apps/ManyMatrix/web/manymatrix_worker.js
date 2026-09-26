let wasmCall;
let protocol;
// Installed once the module is ready; see handleFatalEvent.
let runtime;

self.onmessage = async (event) => {
  // Disposal can race module initialization, so recognize close without
  // dereferencing the asynchronously imported protocol module.
  if (event.data?.type === 'manymatrix-close') {
    try {
      if (wasmCall && !runtime?.error) await wasmCall('sync.stop', '{}');
    } catch (_) {
      // Closing must not depend on the runtime answering.
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
  if (runtime && !runtime.begin(request.id)) {
    self.postMessage(protocol.errorMessage(request.id, runtime.error));
    return;
  }
  // A request answered by the fatal latch must not be answered twice.
  const reply = (message) => {
    if (runtime && !runtime.finish(request.id)) return;
    self.postMessage(message);
  };

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
    const envelope = JSON.parse(replyJson);
    let status;
    if (envelope?.ok !== undefined) {
      status = 'ok';
      reply(protocol.resultMessage(request.id, envelope.ok));
    } else if (envelope?.err !== undefined) {
      status = 'error';
      reply(protocol.errorMessage(request.id, envelope.err));
    } else {
      status = 'malformed';
      reply(protocol.errorMessage(request.id, {
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
    // A trap during the synchronous part of the call poisons the instance
    // just like one inside the executor.
    if (runtime && error instanceof WebAssembly.RuntimeError) {
      runtime.trip(error, 'call');
      return;
    }
    reply(protocol.errorMessage(request.id, error));
  }
};

// After the module is ready, any uncaught error or unhandled rejection in
// this Worker comes from the WASM runtime or its glue (a Rust panic aborts
// with a trap in an executor microtask). The instance cannot be trusted
// afterwards: answer every in-flight call, report the fault, and close.
function handleFatalEvent(event) {
  // Default handling would also forward the error to the page's
  // Worker.onerror, which reports it as a module load failure.
  event.preventDefault();
  const cause = event.type === 'unhandledrejection'
    ? event.reason
    : event.error ?? event.message;
  runtime.trip(cause, event.type);
}

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
    runtime = new protocol.FatalFaultLatch({
      postMessage: (message) => self.postMessage(message),
      close: () => self.close(),
    });
    self.addEventListener('error', handleFatalEvent);
    self.addEventListener('unhandledrejection', handleFatalEvent);
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
