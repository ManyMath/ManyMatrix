#![cfg(all(feature = "shadow-tests", target_os = "linux"))]

use anyhow::Result;
use test_harness::shadow::{
    run_latency_encrypted_message_scenario, run_latency_message_scenario,
    run_multi_homeserver_message_scenario, FEDERATED_MESSAGE_TEXT, LATENCY_ENCRYPTED_MESSAGE_TEXT,
    LATENCY_MESSAGE_TEXT,
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

#[test]
#[ignore = "two-server Tuwunel federation under Shadow can take tens of minutes; run explicitly"]
fn multi_homeserver_message_delivery_over_shadow() -> Result<()> {
    let run = run_multi_homeserver_message_scenario(44)?;
    let shadow_config = run.shadow_config()?;

    assert!(
        shadow_config.contains("alice-server"),
        "generated Shadow config does not contain alice-server:\n{shadow_config}"
    );
    assert!(
        shadow_config.contains("bob-server"),
        "generated Shadow config does not contain bob-server:\n{shadow_config}"
    );
    assert!(
        shadow_config
            .contains("federated-message --server-url http://alice-server:8448 --role alice"),
        "generated Shadow config does not contain Alice federated client command:\n{shadow_config}"
    );
    assert!(
        shadow_config.contains("federated-message --server-url http://bob-server:8448 --role bob"),
        "generated Shadow config does not contain Bob federated client command:\n{shadow_config}"
    );

    assert!(
        run.result.success(),
        "Shadow multi-homeserver scenario failed with exit code {}.\nSeed: {}\nData dir: {}\nShadow stdout:\n{}\nShadow stderr:\n{}",
        run.result.exit_code,
        run.result.seed,
        run.result.data_dir.display(),
        run.result.stdout,
        run.result.stderr,
    );

    let bob_stderr = run.result.first_host_stderr("bob-host")?;
    assert!(
        bob_stderr.contains(FEDERATED_MESSAGE_TEXT),
        "Bob host logs did not include the expected federated message receipt.\nBob stderr:\n{}",
        bob_stderr,
    );

    Ok(())
}
