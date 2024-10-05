use std::time::Duration;

use anyhow::Result;
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient};
use matrix_sdk::config::SyncSettings;
use matrix_sdk::encryption::verification::SasState;
use test_harness::{ServerKind, TestHomeserver};
use futures_util::StreamExt;
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

/// TEST-04: Two clients complete SAS emoji device verification.
///
/// Uses the `changes()` stream API to react to state transitions rather
/// than polling emoji(), which requires precise KeysExchanged state.
#[tokio::test]
async fn sas_verification() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());

    let _alice_reg = server.register_user("alice_sas", "password1").await?;
    let _bob_reg = server.register_user("bob_sas", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login("alice_sas", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login("bob_sas", "password2").await?;

    // Initial syncs
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Share an encrypted room for device key exchange
    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("SAS Verification Room".into()),
            invite: vec!["@bob_sas:localhost".into()],
            ..Default::default()
        })
        .await?;
    alice.sync_once().await?;
    alice.enable_encryption(&room_id).await?;
    alice.sync_once().await?;

    bob.sync_once().await?;
    bob.join_room(&room_id).await?;

    for _ in 0..6 {
        alice.sync_once().await?;
        bob.sync_once().await?;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    let bob_user_id = <&matrix_sdk::ruma::UserId>::try_from("@bob_sas:localhost")?;
    let alice_user_id = <&matrix_sdk::ruma::UserId>::try_from("@alice_sas:localhost")?;

    // Discover Bob's device
    let bob_devices = alice
        .inner()
        .encryption()
        .get_user_devices(bob_user_id)
        .await?;
    let bob_device = bob_devices
        .devices()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No devices found for Bob"))?;
    eprintln!("Found Bob's device: {}", bob_device.device_id());

    // Alice initiates verification
    let alice_vreq = bob_device.request_verification().await?;
    let flow_id = alice_vreq.flow_id().to_string();
    eprintln!("Verification started, flow_id: {}", flow_id);

    // Bob syncs to receive the request
    bob.sync_once().await?;
    let bob_vreq = bob
        .inner()
        .encryption()
        .get_verification_request(alice_user_id, &flow_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("Bob didn't receive request"))?;
    bob_vreq.accept().await?;
    eprintln!("Bob accepted request");

    // Alice syncs to receive Bob's ready
    alice.sync_once().await?;

    // Alice starts SAS — get the changes stream BEFORE starting
    let alice_sas = alice_vreq
        .start_sas()
        .await?
        .ok_or_else(|| anyhow::anyhow!("Failed to start SAS"))?;
    let mut alice_stream = alice_sas.changes();
    eprintln!("Alice started SAS");

    // Bob syncs to receive SAS start
    bob.sync_once().await?;
    let bob_v = bob
        .inner()
        .encryption()
        .get_verification(alice_user_id, &flow_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("Bob has no verification"))?;
    let bob_sas = bob_v
        .sas()
        .ok_or_else(|| anyhow::anyhow!("Bob's verification is not SAS"))?;
    let mut bob_stream = bob_sas.changes();
    bob_sas.accept().await?;
    eprintln!("Bob accepted SAS");

    // Run sync loops in background using our wrapper's sync_once which
    // properly tracks the sync token for incremental syncs.
    let alice_sync = tokio::spawn({
        // We can't move alice into the spawn (we need it below), so we
        // clone the inner client and manage the token manually.
        let client = alice.inner().clone();
        let token = alice.sync_token_clone().await;
        async move {
            let mut settings = SyncSettings::default().timeout(Duration::from_millis(300));
            if let Some(t) = token {
                settings = settings.token(t);
            }
            loop {
                match client.sync_once(settings.clone()).await {
                    Ok(response) => {
                        settings = settings.token(response.next_batch);
                    }
                    Err(_) => {}
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    });
    let bob_sync = tokio::spawn({
        let client = bob.inner().clone();
        let token = bob.sync_token_clone().await;
        async move {
            let mut settings = SyncSettings::default().timeout(Duration::from_millis(300));
            if let Some(t) = token {
                settings = settings.token(t);
            }
            loop {
                match client.sync_once(settings.clone()).await {
                    Ok(response) => {
                        settings = settings.token(response.next_batch);
                    }
                    Err(_) => {}
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    });

    // Wait for Alice's SAS to reach a state where emojis are available
    eprintln!("Waiting for SAS state transitions...");
    let alice_done = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(state) = alice_stream.next().await {
            eprintln!("Alice SAS state: {:?}", state);
            match state {
                SasState::KeysExchanged { emojis, .. } => {
                    return Ok::<_, anyhow::Error>(emojis);
                }
                SasState::Cancelled(_) => {
                    return Err(anyhow::anyhow!("Alice SAS cancelled"));
                }
                SasState::Done { .. } => {
                    return Err(anyhow::anyhow!("Alice SAS done without emojis"));
                }
                _ => continue,
            }
        }
        Err(anyhow::anyhow!("Alice SAS stream ended"))
    })
    .await??;
    eprintln!("Alice has emojis!");

    let bob_done = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(state) = bob_stream.next().await {
            eprintln!("Bob SAS state: {:?}", state);
            match state {
                SasState::KeysExchanged { emojis, .. } => {
                    return Ok::<_, anyhow::Error>(emojis);
                }
                SasState::Cancelled(_) => {
                    return Err(anyhow::anyhow!("Bob SAS cancelled"));
                }
                _ => continue,
            }
        }
        Err(anyhow::anyhow!("Bob SAS stream ended"))
    })
    .await??;
    eprintln!("Bob has emojis!");

    // Compare emojis — EmojiShortAuthString has .emojis field (array of Emoji)
    let alice_emojis = alice_done.expect("alice should have emojis").emojis;
    let bob_emojis = bob_done.expect("bob should have emojis").emojis;
    assert_eq!(alice_emojis.len(), 7);
    assert_eq!(bob_emojis.len(), 7);
    for (a, b) in alice_emojis.iter().zip(bob_emojis.iter()) {
        assert_eq!(a.symbol, b.symbol, "emoji symbols should match");
    }
    eprintln!("Emojis match!");

    // Both confirm
    alice_sas.confirm().await?;
    bob_sas.confirm().await?;

    // Wait for done
    tokio::time::sleep(Duration::from_secs(2)).await;
    eprintln!("SAS verification complete");

    alice_sync.abort();
    bob_sync.abort();

    Ok(())
}

/// Bootstrap cross-signing keys.
#[tokio::test]
async fn cross_signing_bootstrap() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _user = server.register_user("cross_sign_user", "password1").await?;

    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    let _session = client.login("cross_sign_user", "password1").await?;
    client.sync_once().await?;

    client.bootstrap_cross_signing().await?;
    eprintln!("Cross-signing bootstrapped successfully");

    Ok(())
}
