# manymatrix web/extension E2E harness

`ordinary_matrix.mjs` launches the in-process Tuwunel homeserver and a fresh
headless browser profile. It exercises the ordinary module-Worker transport
without hosted secrets: two isolated account Workers, login, invitation and
room details, create/join, send/receive events, plain and encrypted byte-for-byte media
upload/download round trip, IndexedDB session restoration, and explicit Worker
teardown.

`full_app.mjs` drives the built Flutter application through its accessibility
DOM and real Flutter pointer/keyboard input in a fresh browser profile. It
verifies tab-scoped secret storage with no localStorage token copy, reload
restoration, a nonblank/overflow-free mobile viewport, room creation and
sending, per-message threads and the global unread thread index, adding and
switching accounts, and final session/IndexedDB cleanup.

```sh
scripts/build_manymatrix_web.sh
cargo build -p test-harness --bin web_e2e_actor
(cd testing/web-e2e && npm ci)
node testing/web-e2e/ordinary_matrix.mjs
node testing/web-e2e/full_app.mjs
```

The same embedded actor can verify the MV3 coordinator without hosted secrets:

```sh
bash scripts/assemble_web_e2e_extension.sh /tmp/manymatrix-extension
EXTENSION_DIR=/tmp/manymatrix-extension node testing/web-e2e/run.mjs embedded
```

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
5. Assembles a manifest with no web-accessible privileged host/WASM resources;
   extension startup also scrubs the former global session key and legacy
   URL-derived IndexedDB namespaces before any Matrix Worker is opened.

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
