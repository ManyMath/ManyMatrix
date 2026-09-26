import assert from 'node:assert/strict';
import test from 'node:test';

import {
  closedMessage,
  errorMessage,
  FatalFaultLatch,
  fatalError,
  fatalMessage,
  initErrorMessage,
  messageTypes,
  parseCallRequest,
  ProtocolError,
  resultMessage,
} from '../web/manymatrix_worker_protocol.mjs';

test('parseCallRequest accepts a typed call envelope', () => {
  const request = parseCallRequest({
    type: messageTypes.call,
    id: 7,
    method: 'rooms.list',
    args: {},
  });

  assert.deepEqual(request, {id: 7, method: 'rooms.list', args: {}});
});

test('parseCallRequest rejects malformed ids, methods, and args', () => {
  for (const request of [
    {type: messageTypes.call, id: 0, method: 'rooms.list', args: {}},
    {type: messageTypes.call, id: 1, method: '', args: {}},
    {type: messageTypes.call, id: 1, method: 'rooms.list', args: []},
  ]) {
    assert.throws(() => parseCallRequest(request), ProtocolError);
  }
});

test('reply helpers preserve request ids and normalize errors', () => {
  assert.deepEqual(resultMessage(4, {rooms_json: '[]'}), {
    type: messageTypes.result,
    id: 4,
    ok: {rooms_json: '[]'},
  });
  assert.deepEqual(
    errorMessage(4, {kind: 'MatrixSdkError', message: 'failed'}),
    {
      type: messageTypes.error,
      id: 4,
      error: {kind: 'MatrixSdkError', message: 'failed', details: {}},
    },
  );
  assert.equal(initErrorMessage(new Error('load failed')).error.kind, 'PanicError');
});

test('closedMessage provides an explicit lifecycle acknowledgement', () => {
  assert.deepEqual(closedMessage(), {type: messageTypes.closed});
});

test('fatalError describes a WASM trap as a PanicError', () => {
  const error = fatalError(
    new WebAssembly.RuntimeError('unreachable'),
    'error',
  );

  assert.equal(error.kind, 'PanicError');
  assert.match(error.message, /panic/);
  assert.match(error.message, /RuntimeError: unreachable/);
  assert.deepEqual(error.details, {
    reason: 'runtime_fatal',
    cause: 'RuntimeError: unreachable',
    source: 'error',
  });
  assert.equal(fatalError(undefined).details.cause, 'unknown error');
  assert.equal(fatalError({message: 'Uncaught boom'}).details.cause, 'Uncaught boom');
  assert.equal('source' in fatalError('boom').details, false);
});

test('fatalMessage carries a normalized error', () => {
  const error = fatalError('boom');
  assert.deepEqual(fatalMessage(error), {type: messageTypes.fatal, error});
  assert.equal(messageTypes.fatal, 'manymatrix-fatal');
});

function fakeScope() {
  return {posted: [], closeCount: 0};
}

function latchFor(scope) {
  return new FatalFaultLatch({
    postMessage: (message) => scope.posted.push(message),
    close: () => {
      scope.closeCount += 1;
    },
  });
}

test('a fatal fault answers every in-flight request, reports once, and closes', () => {
  const scope = fakeScope();
  const latch = latchFor(scope);
  assert.equal(latch.begin(1), true);
  assert.equal(latch.begin(2), true);
  assert.equal(latch.begin(3), true);
  assert.equal(latch.finish(2), true);

  assert.equal(latch.trip(new WebAssembly.RuntimeError('unreachable'), 'error'), true);

  assert.deepEqual(
    scope.posted.map((message) => [message.type, message.id]),
    [
      [messageTypes.error, 1],
      [messageTypes.error, 3],
      [messageTypes.fatal, undefined],
    ],
  );
  for (const message of scope.posted) {
    assert.equal(message.error.kind, 'PanicError');
    assert.equal(message.error.details.reason, 'runtime_fatal');
  }
  assert.equal(scope.closeCount, 1);
  assert.equal(latch.error.kind, 'PanicError');
});

test('only the first fatal fault is reported', () => {
  const scope = fakeScope();
  const latch = latchFor(scope);
  latch.trip(new Error('first'), 'error');

  assert.equal(latch.trip(new Error('second'), 'unhandledrejection'), false);

  assert.equal(scope.posted.length, 1);
  assert.equal(scope.closeCount, 1);
  assert.match(latch.error.message, /first/);
});

test('a poisoned runtime refuses new requests and ignores late replies', () => {
  const scope = fakeScope();
  const latch = latchFor(scope);
  latch.begin(4);
  latch.trip(new Error('trap'));

  assert.equal(latch.begin(5), false);
  // Request 4 was answered by trip(), so a late settlement must be dropped.
  assert.equal(latch.finish(4), false);
  assert.equal(latch.finish(5), false);
});
