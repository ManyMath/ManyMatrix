# Test Harness

The test harness owns ManyMatrix end-to-end homeserver tiers and compatibility reporting.

## Compatibility Commands

Embedded Tuwunel is the default fast local tier:

```bash
cargo test -p test-harness
scripts/compatibility.sh embedded
```

Generate the embedded compatibility report:

```bash
cargo test -p test-harness compatibility_report --no-default-features --features embedded-tests -- --nocapture
scripts/compatibility.sh report
```

The report is retained at:

```text
target/compat/compatibility-report.json
```

Docker and Shadow are opt-in. They are not part of the default test command:

```bash
cargo test -p test-harness compatibility_report --features docker-tests -- --nocapture
scripts/compatibility.sh docker

cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- --nocapture
scripts/compatibility.sh shadow
```

`scripts/compatibility.sh all-local` runs only embedded and report tiers. It intentionally excludes Docker and Shadow so CI-like local automation stays deterministic on hosts without Docker or Shadow installed.

## Compatibility Report

Generate the embedded Tuwunel compatibility baseline:

```bash
cargo test -p test-harness compatibility_report --no-default-features --features embedded-tests
```

The report is written to:

```text
target/compat/compatibility-report.json
```

The embedded run is the default fast local tier. It records server metadata, `/_matrix/client/versions`, and behavior rows for auth, sync, rooms, messaging, media, E2EE, and FFI smoke coverage.

Compile the Docker-inclusive tier:

```bash
cargo test -p test-harness --features docker-tests --no-run
```

Run the Docker-inclusive compatibility report when Docker is available:

```bash
cargo test -p test-harness compatibility_report --features docker-tests
```

Docker coverage includes Synapse and Docker Tuwunel in addition to embedded Tuwunel. Synapse is deliberately pinned as the reference homeserver image:

```text
ghcr.io/matrix-org/synapse-service:v1.117.0
```

Docker Tuwunel is alternate-server coverage. Embedded Tuwunel remains the default local feedback loop.

## Shadow Tier

Shadow tests are optional and Linux-only:

```bash
cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- --nocapture
scripts/compatibility.sh shadow
```

The standard Shadow tier includes single-homeserver latency scenarios and encrypted-message latency coverage. The multi-homeserver scenario with clients on distinct homeservers is intentionally ignored because upstream two-server Tuwunel federation under Shadow can take tens of minutes; run it explicitly when needed:

```bash
cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- multi_homeserver_message_delivery_over_shadow --ignored --nocapture
scripts/compatibility.sh shadow-multi
```

Shadow prerequisites are:

- Linux host.
- Dynamically linked `x86_64-unknown-linux-gnu` binaries; the harness checks this with `ldd`.
- `shadow` installed and available on `PATH`.
- `seccomp=unconfined` when running inside Docker or another restricted container.

Docker and Shadow are sufficient for local compatibility validation. Shadow's multi-homeserver scenario simulates federation over a virtual network; it does not exercise real internet server-to-server delivery.

## Hosted Tier

The hosted tier targets the permanently hosted `synapse.manymatrix.com` and `tuwunel.manymatrix.com` instances (see `~/dev/hetzner` for server-side config):

```bash
MANYMATRIX_HOSTED_SYNAPSE_URL=... \
MANYMATRIX_HOSTED_SYNAPSE_REGISTRATION_SECRET=... \
MANYMATRIX_HOSTED_TUWUNEL_URL=... \
MANYMATRIX_HOSTED_TUWUNEL_REGISTRATION_TOKEN=... \
  scripts/compatibility.sh hosted
```

This runs the standard E2E scenarios (`testing/test-harness/tests/e2e.rs`) against each hosted server individually, plus `testing/test-harness/tests/hosted_federation.rs` (COMP-06): a room created on one hosted server, joined by full alias from a client logged into the *other* hosted server, with a message sent across that join. Because the two servers are on genuinely distinct public domains, this only passes via real server-to-server federation over the open internet, unlike Shadow's simulated-network federation test above, or same-server tests where "federation" never leaves one homeserver.
