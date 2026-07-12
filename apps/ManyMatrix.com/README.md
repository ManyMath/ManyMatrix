# ManyMatrix.com

The ManyMatrix product site and web client are deployed as one static
distribution:

- `/` introduces ManyMatrix and links the wider ManyMath product family.
- `/chat/` serves the production Flutter web client.

## Build

From the repository root, run:

```sh
./apps/ManyMatrix.com/tool/build_web.sh
```

The build requires Flutter, `wasm-pack`, the Rust `wasm32-unknown-unknown`
target, and the sibling `ManyUI` checkout. It builds the Rust web runtime and
Flutter client with a `/chat/` base path, then creates the deployable directory
at `apps/ManyMatrix.com/build/dist`.

Verify an existing distribution without rebuilding it:

```sh
./apps/ManyMatrix.com/tool/verify_web_dist.sh
```

For a local preview:

```sh
python3 -m http.server 8181 --bind 127.0.0.1 \
  --directory apps/ManyMatrix.com/build/dist
```

Open `http://127.0.0.1:8181/` for the product site or
`http://127.0.0.1:8181/chat/` for the client.

## Deploy

Upload the **contents** of `apps/ManyMatrix.com/build/dist` to the
ManyMatrix.com Cloudflare Pages project. Keep the complete `/chat/` directory;
the app requires its Worker, JavaScript modules, and WebAssembly binary.
