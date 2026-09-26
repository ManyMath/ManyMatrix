export const messageTypes = Object.freeze({
  call: 'manymatrix-call',
  close: 'manymatrix-close',
  closed: 'manymatrix-closed',
  ready: 'manymatrix-ready',
  initError: 'manymatrix-init-error',
  result: 'manymatrix-result',
  error: 'manymatrix-error',
  event: 'manymatrix-event',
  fatal: 'manymatrix-fatal',
});

export class ProtocolError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProtocolError';
  }
}

export function parseCallRequest(value) {
  if (!isRecord(value) || value.type !== messageTypes.call) {
    throw new ProtocolError('expected a manymatrix-call message');
  }
  if (!Number.isSafeInteger(value.id) || value.id < 1) {
    throw new ProtocolError('request id must be a positive safe integer');
  }
  if (typeof value.method !== 'string' || value.method.length === 0) {
    throw new ProtocolError('method must be a non-empty string');
  }
  if (!isRecord(value.args)) {
    throw new ProtocolError('args must be an object');
  }
  return {id: value.id, method: value.method, args: value.args};
}

export function resultMessage(id, ok) {
  return {type: messageTypes.result, id, ok: isRecord(ok) ? ok : {}};
}

export function closedMessage() {
  return {type: messageTypes.closed};
}

export function errorMessage(id, error) {
  return {
    type: messageTypes.error,
    id,
    error: normalizeError(error),
  };
}

export function initErrorMessage(error) {
  return {type: messageTypes.initError, error: normalizeError(error)};
}

// The WASM build is panic=abort: a Rust panic runs the panic hook and then
// traps (`RuntimeError: unreachable`) inside the futures executor. The call
// that panicked never settles and the instance is left in an unknown state,
// so the Worker reports the fault once and stops serving calls.
export function fatalError(cause, source) {
  const description = describeCause(cause);
  return {
    kind: 'PanicError',
    message:
      'The ManyMatrix WASM runtime stopped after a Rust panic or trap: ' +
      description,
    details: {
      reason: 'runtime_fatal',
      cause: description,
      ...(typeof source === 'string' ? {source} : {}),
    },
  };
}

export function fatalMessage(error) {
  return {type: messageTypes.fatal, error: normalizeError(error)};
}

// Tracks the requests the WASM module is serving so the first fatal fault
// can answer each of them, since their promises will never settle.
export class FatalFaultLatch {
  #inFlight = new Set();
  #error = null;
  #post;
  #close;

  constructor({postMessage, close}) {
    this.#post = postMessage;
    this.#close = close;
  }

  get error() {
    return this.#error;
  }

  // Returns false once the runtime is poisoned; reply with `error` instead.
  begin(id) {
    if (this.#error) return false;
    this.#inFlight.add(id);
    return true;
  }

  // Returns false when the request was already answered by trip().
  finish(id) {
    return this.#inFlight.delete(id);
  }

  trip(cause, source) {
    if (this.#error) return false;
    this.#error = fatalError(cause, source);
    for (const id of this.#inFlight) {
      this.#post(errorMessage(id, this.#error));
    }
    this.#inFlight.clear();
    this.#post(fatalMessage(this.#error));
    this.#close();
    return true;
  }
}

function describeCause(cause) {
  if (cause instanceof Error) {
    return cause.message ? `${cause.name}: ${cause.message}` : cause.name;
  }
  if (isRecord(cause) && typeof cause.message === 'string') {
    return cause.message;
  }
  return cause === undefined ? 'unknown error' : String(cause);
}

export function normalizeError(error) {
  if (isRecord(error) && typeof error.kind === 'string') {
    return {
      kind: error.kind,
      message: typeof error.message === 'string' ? error.message : '',
      details: isRecord(error.details) ? error.details : {},
    };
  }
  return {
    kind: error instanceof ProtocolError ? 'SerdeError' : 'PanicError',
    message: error instanceof Error ? error.message : String(error),
    details: {},
  };
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
