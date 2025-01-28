#![cfg(all(feature = "shadow-tests", target_os = "linux"))]

use anyhow::Result;
use test_harness::shadow::{
    run_latency_encrypted_message_scenario, run_latency_message_scenario,
    LATENCY_ENCRYPTED_MESSAGE_TEXT, LATENCY_MESSAGE_TEXT,
};

#[test]
fn latency_message_delivery_over_shadow() -> Result<()> {
    let run = run_latency_message_scenario(42)?;
    let shadow_config = run.shadow_config()?;

    assert!(
        shadow_config.contains("latency \"150 ms\""),
        "generated Shadow config does not contain the expected latency topology:\n{shadow_config}"
    );

    assert!(
        run.result.success(),
        "Shadow scenario failed with exit code {}.\nSeed: {}\nData dir: {}\nShadow stdout:\n{}\nShadow stderr:\n{}",
        run.result.exit_code,
        run.result.seed,
        run.result.data_dir.display(),
        run.result.stdout,
        run.result.stderr,
    );

    let bob_stderr = run.result.first_host_stderr("bob-host")?;
    assert!(
        bob_stderr.contains(LATENCY_MESSAGE_TEXT),
        "Bob host logs did not include the expected message receipt.\nBob stderr:\n{}",
        bob_stderr,
    );

    Ok(())
}

#[test]
fn latency_encrypted_message_delivery_over_shadow() -> Result<()> {
    let run = run_latency_encrypted_message_scenario(43)?;
    let shadow_config = run.shadow_config()?;

    assert!(
        shadow_config.contains("latency \"150 ms\""),
        "generated Shadow config does not contain the expected latency topology:\n{shadow_config}"
    );

    assert!(
        run.result.success(),
        "Shadow encrypted scenario failed with exit code {}.\nSeed: {}\nData dir: {}\nShadow stdout:\n{}\nShadow stderr:\n{}",
        run.result.exit_code,
        run.result.seed,
        run.result.data_dir.display(),
        run.result.stdout,
        run.result.stderr,
    );

    let bob_stderr = run.result.first_host_stderr("bob-host")?;
    assert!(
        bob_stderr.contains(LATENCY_ENCRYPTED_MESSAGE_TEXT),
        "Bob host logs did not include the expected encrypted message receipt.\nBob stderr:\n{}",
        bob_stderr,
    );

    Ok(())
}
