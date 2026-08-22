# ManyMatrix

ManyMatrix is a Flutter Matrix client backed by the Rust `manymatrix-core`.
Native builds use FFI. Ordinary browser builds run one Rust WASM instance in a
dedicated module Worker for each active account; the Chrome extension continues
to use its MV3 offscreen transport.

## Web development

Requirements: Flutter, Rust with `wasm32-unknown-unknown`, `wasm-pack`, Node.js
18 or newer, and the sibling `ManyUI` checkout used by the app's path
dependencies. Browser E2E uses Puppeteer's bundled Chrome.

CI reproduces that sibling layout with the read-only
`MANYUI_CHECKOUT_TOKEN` secret and pins the compatible ManyUI revision directly
as a full commit SHA. Push coordinated ManyUI changes before the ManyMatrix
changes that consume them, then update the workflow pin.

Build the complete development bundle from the repository root:

```sh
scripts/build_manymatrix_web.sh --debug
```

Build the optimized release bundle with the same wrapper (release is the
default used by CI):

```sh
scripts/build_manymatrix_web.sh
```

The command builds `crates/web`, packages its JavaScript and WASM into the
Flutter web scaffold, builds Flutter, and verifies every required artifact.
Serve the resulting `apps/ManyMatrix/build/web` directory over HTTP or HTTPS;
opening `index.html` directly cannot start a module Worker.

For a local preview:

```sh
python3 -m http.server 8181 --bind 127.0.0.1 \
  --directory apps/ManyMatrix/build/web
```

Then open `http://127.0.0.1:8181`.

Pass Flutter web build options through the wrapper, for example:

```sh
scripts/build_manymatrix_web.sh --base-href=/matrix/
```

## Deployment and security

- Deploy the whole `build/web` directory. The Worker requires
  `manymatrix_worker.js`, `manymatrix_worker_protocol.mjs`,
  `pkg/manymatrix_web.js`, and `pkg/manymatrix_web_bg.wasm`.
- Serve `.wasm` as `application/wasm` and JavaScript modules with a JavaScript
  MIME type.
- Use HTTPS in browser production. The web runtime rejects non-HTTPS
  homeservers and an insecure production page; HTTP is accepted there only
  for localhost/loopback development. Native clients retain HTTP support.
- The homeserver must permit Matrix client requests from the web app's origin
  through CORS. ManyMatrix reports a focused CORS/network error when it cannot.
- Each saved account has a distinct Worker, IndexedDB database name, session
  namespace, and sync lifecycle. Switching terminates its Worker. Forgetting
  or signing out also removes its account-scoped IndexedDB databases.
- Ordinary-site access and refresh tokens live only in tab-scoped
  `sessionStorage`: reload works, but a new/closed tab has no local session.
  Non-secret account labels remain in `localStorage`. The extension uses its
  isolated `chrome.storage.local`; native hosts retain their existing session
  persistence path. Legacy ordinary-site session values are migrated out of
  `localStorage` and deleted.
- Attachments with an advertised size above 25 MiB are rejected before the
  request. Response bodies are then streamed with a per-chunk 25 MiB cap, so
  an absent or dishonest `Content-Length` cannot force an unbounded Worker
  allocation or cache copy.
  Message events retain the complete Matrix media source, so downloads in
  encrypted rooms use authenticated media endpoints, verify the ciphertext
  hash, and decrypt within the same bound. The cap is enforced again before
  bridge base64 encoding; files above it are unsupported.
- Sync runs only while the page is open. Closed-tab delivery requires a
  separately deployed push service and is not part of this browser runtime.

## Threads

Every top-level message exposes a thread action. Homeserver-provided
`m.thread` aggregates supply reply counts and latest activity; opening a thread
loads its root and paginated replies through `/relations`. The global Threads
shortcut queries `/threads` across joined rooms with bounded concurrency.
The Recent view includes the newest page per room plus every older root with
unread activity. If any room cannot be indexed, the index reports an explicit
unavailable state rather than silently hiding that room; room navigation and
per-message threads remain usable.

Unread thread counts use the homeserver's `unread_thread_notifications` sync
aggregate, so they follow the account's Matrix push rules. The lookup is a
stateless, zero-timeline snapshot: its `next_batch` is never reused, preventing
the auxiliary request from acknowledging unprocessed to-device events. A
failed or incomplete lookup is shown as unknown, not as a false zero. Reading a
thread sends a receipt scoped to its root; transient failures retry without
leaving an optimistic read marker in place.

## Verification

```sh
cargo check -p manymatrix-web --target wasm32-unknown-unknown
node --test apps/ManyMatrix/test_web/*.mjs
(cd apps/ManyMatrix && flutter test)
scripts/build_manymatrix_web.sh
cargo build -p test-harness --bin web_e2e_actor
(cd testing/web-e2e && npm ci)
node testing/web-e2e/ordinary_matrix.mjs
node testing/web-e2e/full_app.mjs
```

If the login page reports missing runtime assets, rebuild with the wrapper and
deploy the complete output. If it reports CORS, inspect the homeserver's
`Access-Control-Allow-Origin` response and confirm that the URL uses HTTPS.
