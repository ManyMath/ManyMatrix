export const messageTypes = Object.freeze({
  call: 'manymatrix-call',
  close: 'manymatrix-close',
  closed: 'manymatrix-closed',
  ready: 'manymatrix-ready',
  initError: 'manymatrix-init-error',
  result: 'manymatrix-result',
  error: 'manymatrix-error',
  event: 'manymatrix-event',
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
