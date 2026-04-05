// Manual probe: run 'await chrome.offscreen.closeDocument()' from SW DevTools console
// to induce offscreen loss. Next forwarded message triggers ensureOffscreenDocument
// and the recovery path.

let offscreenFailCount = 0;

chrome.runtime.onInstalled.addListener(() => {
  chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === 'openTab') {
    chrome.tabs.create({url: chrome.runtime.getURL('index.html')});
    sendResponse({ok: true});
    return;
  }

  if (message?.type === 'offscreen-ready' || message?.type === 'offscreen-ready-failed') {
    return;
  }

  if (message?.target === 'offscreen' || (message && !message.type)) {
    console.debug('[sw] forwarding envelope', {method: message.method});
    ensureOffscreenDocument()
      .then(() => forwardToOffscreen(message))
      .then(reply => sendResponse(reply))
      .catch(err => sendResponse({
        err: {kind: 'StorageError', message: err?.message ?? String(err), details: {count: offscreenFailCount}}
      }));
    return true;
  }
});

async function ensureOffscreenDocument() {
  const has = await chrome.offscreen.hasDocument();
  console.debug('[sw] ensuring offscreen doc, hasDocument=', has);
  if (has) { offscreenFailCount = 0; return; }
  try {
    try {
      await chrome.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['IFRAME_SCRIPTING'],
        justification: 'Host manymatrix WASM for persistent Matrix sync'
      });
    } catch (createErr) {
      if (String(createErr).includes('Only a single offscreen document may be created')) {
        offscreenFailCount = 0;
        console.debug('[sw] offscreen already present (race)');
        await waitForOffscreenReady();
        return;
      }
      throw createErr;
    }
    await waitForOffscreenReady();
    offscreenFailCount = 0;
    console.debug('[sw] offscreen recreated (attempt', offscreenFailCount, ')');
  } catch (err) {
    offscreenFailCount++;
    console.error('[sw] offscreen recreation failed (count=', offscreenFailCount, ')', err);
    if (offscreenFailCount >= 2) {
      throw new Error('background sync stopped');
    }
    throw err;
  }
}

function waitForOffscreenReady() {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      chrome.runtime.onMessage.removeListener(listener);
      reject(new Error('offscreen did not become ready within 5s'));
    }, 5000);

    function listener(message) {
      if (message?.type === 'offscreen-ready') {
        clearTimeout(timeout);
        chrome.runtime.onMessage.removeListener(listener);
        resolve();
      } else if (message?.type === 'offscreen-ready-failed') {
        clearTimeout(timeout);
        chrome.runtime.onMessage.removeListener(listener);
        reject(new Error(message.error ?? 'offscreen init failed'));
      }
    }

    chrome.runtime.onMessage.addListener(listener);
  });
}

function forwardToOffscreen(envelope) {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => {
      resolve({err: {kind: 'StorageError', message: 'offscreen no reply', details: {}}});
    }, 30000);

    chrome.runtime.sendMessage({target: 'offscreen-call', envelope}, (reply) => {
      clearTimeout(timeout);
      resolve(reply);
    });
  });
}
