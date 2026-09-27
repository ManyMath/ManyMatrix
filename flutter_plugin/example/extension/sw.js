// Manual probe: run 'await chrome.offscreen.closeDocument()' from SW DevTools console
// to induce offscreen loss. Next forwarded message triggers ensureOffscreenDocument
// and the recovery path.

import {
  OffscreenDocumentManager,
  rpcTimeoutMs,
} from './worker_lifecycle.mjs';
import {LegacyExtensionStorageScrubber} from './legacy_storage.mjs';

let offscreenFailCount = 0;

const legacyStorage = new LegacyExtensionStorageScrubber({
  storageLocal: chrome.storage.local,
  indexedDb: indexedDB,
});
// Fail closed before any offscreen document or Matrix Worker can open a
// database. A rejected attempt remains retryable on the next inbound RPC.
legacyStorage.ensure().catch(() => {});

const offscreenDocuments = new OffscreenDocumentManager({
  hasDocument: () => chrome.offscreen.hasDocument(),
  createDocument: () => chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: ['IFRAME_SCRIPTING'],
    justification: 'Host manymatrix WASM for persistent Matrix sync',
  }),
  closeDocument: () => chrome.offscreen.closeDocument(),
  probeReady: probeOffscreenReady,
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === 'manymatrix-legacy-storage') {
    const options = {
      expectedHomeserverUrl: message.expected_homeserver_url,
      scopedSessionKey: message.scoped_session_key,
    };
    const operation = message.action === 'ensure'
      ? legacyStorage.ensure(options)
      : legacyStorage.scrub(options);
    operation
      .then((result) => sendResponse({ok: result}))
      .catch((error) => sendResponse({
        err: {
          kind: 'StorageError',
          message: error?.message ?? String(error),
          details: {reason: 'legacy_storage_cleanup_failed'},
        },
      }));
    return true;
  }

  if (message?.type === 'openTab') {
    chrome.tabs.create({url: chrome.runtime.getURL('index.html')});
    sendResponse({ok: true});
    return;
  }

  if (message?.target === 'offscreen-health' ||
      message?.target === 'offscreen-call' ||
      message?.type === 'manymatrix-event') {
    return;
  }

  if (message?.target === 'offscreen' || (message && !message.type)) {
    console.debug('[sw] forwarding envelope', {method: message.method});
    legacyStorage.ensure()
      .then(() => ensureOffscreenDocument())
      .then(() => forwardToOffscreen(message))
      .then(reply => sendResponse(reply))
      .catch(err => sendResponse({
        err: {kind: 'StorageError', message: err?.message ?? String(err), details: {count: offscreenFailCount}}
      }));
    return true;
  }
});

async function ensureOffscreenDocument() {
  try {
    const result = await offscreenDocuments.ensure();
    offscreenFailCount = 0;
    console.debug('[sw] offscreen ready', result);
  } catch (err) {
    offscreenFailCount++;
    console.error('[sw] offscreen recreation failed (count=', offscreenFailCount, ')', err);
    if (offscreenFailCount >= 2) {
      throw new Error('background sync stopped');
    }
    throw err;
  }
}

async function probeOffscreenReady() {
  const reply = await chrome.runtime.sendMessage({target: 'offscreen-health'});
  return reply?.type === 'offscreen-health-ack' && reply.ready === true;
}

function forwardToOffscreen(envelope) {
  return new Promise((resolve) => {
    const timeoutMs = rpcTimeoutMs(envelope?.method, envelope?.args);
    const timeout = setTimeout(() => {
      resolve({err: {kind: 'StorageError', message: 'offscreen no reply', details: {}}});
    }, timeoutMs);

    chrome.runtime.sendMessage({target: 'offscreen-call', envelope}, (reply) => {
      clearTimeout(timeout);
      resolve(reply);
    });
  });
}
