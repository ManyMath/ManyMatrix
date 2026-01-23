# Test Harness

The test harness owns ManyMatrix end-to-end homeserver tiers and compatibility reporting.

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
