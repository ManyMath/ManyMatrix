import assert from 'node:assert/strict';
import test from 'node:test';

import {
  closedMessage,
  errorMessage,
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
