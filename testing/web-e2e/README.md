# manymatrix web/extension E2E harness

End-to-end test of the Chrome extension web bridge, including the event push
channel (offscreen -> `chrome.runtime` broadcast), against the permanently
hosted homeservers (roadmap v1.3, Phase 25).

## What it does

`run.mjs` copies the built extension (`flutter_plugin/example/build/extension`)
into a temp dir, injects a minimal `e2e.html` driver page, and loads it into
headless Chrome for Testing (puppeteer's bundled browser; new headless supports
MV3 extensions, and branded Google Chrome >= 137 removed `--load-extension`, so
the system Chrome won't work). It then:

1. Verifies envelope basics through the real sw -> offscreen -> WASM path
   (`dispatcher.echo`, `auth.login`, `rooms.list`, `rooms.create`,
   `messages.send_text`).
2. Spawns `web_e2e_actor` (a native `manymatrix-core` client from
   `testing/test-harness`), which registers both test users and acts as the
   remote party: it joins the room, then sends a message, a reaction, and a
   read receipt.
3. Asserts each of those arrives in the extension page as a
   `manymatrix-event` broadcast (`message` / `reaction` / `receipt`) with the
   correct payload, the same `chrome.runtime.onMessage` channel the Dart
   `WebBridge` consumes.
4. Kills the offscreen document from the service worker and verifies
   transparent recovery: the next envelope recreates it, `auth.restore` from
   the IndexedDB store succeeds, and the push channel works again.

The actor cleans up on exit (leave + forget all rooms for both users; hosted
usernames are per-run unique).

## Running

Requires the four `MANYMATRIX_HOSTED_*` env vars (secrets live on the Hetzner
box, see `~/dev/hetzner/README.md` section 8) and Node; `npm install` fetches
puppeteer with its Chrome for Testing build.

```sh
scripts/verify_s03_web.sh          # builds everything, runs both servers
# or directly, after building the extension and the actor:
node run.mjs hosted-synapse
node run.mjs hosted-tuwunel
```

Env overrides: `CHROME_BIN`, `EXTENSION_DIR`, `ACTOR_BIN`.
