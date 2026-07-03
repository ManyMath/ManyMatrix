//! Standalone embedded Tuwunel homeserver for interactive spikes.
//!
//! Starts the same in-process Tuwunel tier the embedded test suite uses, then
//! blocks so a real client (e.g. a Flutter app) can register/login against it
//! over real HTTP, instead of the server tearing down at the end of one test.

use anyhow::Result;
use test_harness::{ServerKind, TestHomeserver};

// Mirrors the private `EMBEDDED_REGISTRATION_TOKEN` constant in `test_harness::lib`,
// which the embedded-Tuwunel tier always registers with.
const EMBEDDED_REGISTRATION_TOKEN: &str = "manymatrix_embed_test_token";

#[tokio::main]
async fn main() -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let server = TestHomeserver::start(ServerKind::TuwunelEmbedded).await?;

    println!("base_url={}", server.base_url());
    println!("registration_token={EMBEDDED_REGISTRATION_TOKEN}");
    println!("ready");

    tokio::signal::ctrl_c().await?;
    Ok(())
}
