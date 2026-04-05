import init, { call } from './pkg/manymatrix_web.js';

async function main() {
  try {
    await init();
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (message?.target === 'offscreen-call') {
        const { method, args } = message.envelope;
        const args_json = JSON.stringify(args ?? {});
        call(method, args_json)
          .then(reply_json => {
            try {
              sendResponse(JSON.parse(reply_json));
            } catch (e) {
              sendResponse({err: {kind: 'SerdeError', message: 'malformed wasm reply', details: {raw: reply_json}}});
            }
          })
          .catch(err => {
            sendResponse({err: {kind: 'PanicError', message: err?.message ?? String(err), details: {}}});
          });
        return true;
      }
    });
    chrome.runtime.sendMessage({type: 'offscreen-ready'});
    console.debug('[offscreen] init done');
  } catch (err) {
    console.error('[offscreen] init failed', err);
    chrome.runtime.sendMessage({type: 'offscreen-ready-failed', error: err?.message ?? String(err)});
  }
}

main();
