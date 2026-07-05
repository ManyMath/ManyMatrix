use std::time::{Duration, Instant};

use anyhow::Result;
use manymatrix_core::{CreateRoomOptions, CustomEvent, ManyMatrixClient};
use serde_json::json;
use test_harness::{ServerKind, TestHomeserver};
use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

const TEST_SYNC_TIMEOUT: Duration = Duration::from_secs(1);
const TEST_SYNC_RETRY_DELAY: Duration = Duration::from_millis(250);
const TEST_SYNC_ATTEMPTS: usize = 5;
const LOCAL_MEDIA_CLOCK_CORRECTION_TOLERANCE: Duration = Duration::from_millis(350);
const ENCRYPTED_CUSTOM_EVENT_LATENCY_SAMPLES: usize = 5;

async fn sync_once_retry(client: &ManyMatrixClient) -> Result<()> {
    let mut last_err = None;

    for attempt in 1..=TEST_SYNC_ATTEMPTS {
        match client.sync_once_with_timeout(TEST_SYNC_TIMEOUT).await {
            Ok(()) => return Ok(()),
            Err(err) => {
                last_err = Some(err);

                if attempt < TEST_SYNC_ATTEMPTS {
                    tokio::time::sleep(TEST_SYNC_RETRY_DELAY).await;
                }
            }
        }
    }

    Err(last_err.expect("retry loop should capture an error").into())
}

async fn sync_pair_retry(alice: &ManyMatrixClient, bob: &ManyMatrixClient) -> Result<()> {
    tokio::try_join!(sync_once_retry(alice), sync_once_retry(bob))?;
    Ok(())
}

fn enforces_local_media_latency_tolerance(kind: ServerKind) -> bool {
    #[cfg(feature = "embedded-tests")]
    {
        return kind == ServerKind::TuwunelEmbedded;
    }

    #[cfg(not(feature = "embedded-tests"))]
    {
        let _ = kind;
        false
    }
}

/// Custom event round-trip: Alice sends an app-specific `io.manymath.test` event with
/// arbitrary JSON content, Bob receives it via `on_custom_event`, proving the generic
/// send/receive mechanism works for an event type this crate has no typed model for.
async fn custom_event_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let alice_reg = server.register_user("alice_custom", "password1").await?;
    let bob_reg = server.register_user("bob_custom", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Custom Event Test Room".into()),
            invite: vec![bob_reg.user_id.clone()],
            ..Default::default()
        })
        .await?;

    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Register on_custom_event on Bob BEFORE sending (Fn, not async), scoped to one
    // event type: a fixed m.room.message sent alongside must NOT be delivered here.
    let (tx, mut rx) = mpsc::channel::<CustomEvent>(16);
    bob.on_custom_event("io.manymath.test", move |ev| {
        let _ = tx.try_send(ev);
    });

    // A same-room m.room.message the custom-event callback should ignore.
    alice.send_text(&room_id, "not a custom event").await?;

    let event_id = alice
        .send_custom_event(
            &room_id,
            "io.manymath.test",
            json!({ "action": "play", "position_ms": 30000 }),
        )
        .await?;
    eprintln!("Alice sent custom event: {}", event_id);

    alice.sync_once().await?;
    bob.sync_once().await?;

    let event = tokio::time::timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("custom event receive timed out")
        .expect("custom event channel closed unexpectedly");

    assert_eq!(event.event_id, event_id);
    assert_eq!(event.room_id, room_id);
    assert_eq!(event.event_type, "io.manymath.test");
    assert_eq!(event.content["action"], "play");
    assert_eq!(event.content["position_ms"], 30000);
    assert!(event.timestamp > 0);

    // Confirm the plain-text message never arrived on the custom-event channel: only one
    // event should ever be receivable, and it must be the custom one already asserted above.
    assert!(
        rx.try_recv().is_err(),
        "on_custom_event must not deliver events of a different type"
    );

    Ok(())
}

/// Encrypted custom event round-trip: `Room::send_raw` should transparently encrypt
/// app-specific custom message-like events in an encrypted room, and `on_custom_event`
/// should receive the decrypted app event shape rather than the outer `m.room.encrypted`.
/// The embedded tier also measures local delivery latency against local_media's current
/// group-session clock-correction tolerance.
async fn encrypted_custom_event_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let alice_reg = server
        .register_user("alice_encrypted_custom", "password1")
        .await?;
    let bob_reg = server
        .register_user("bob_encrypted_custom", "password2")
        .await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Encrypted Custom Event Test Room".into()),
            invite: vec![bob_reg.user_id.clone()],
            ..Default::default()
        })
        .await?;

    sync_pair_retry(&alice, &bob).await?;
    bob.join_room(&room_id).await?;
    sync_pair_retry(&alice, &bob).await?;

    alice.enable_encryption(&room_id).await?;
    sync_once_retry(&alice).await?;

    // Multiple sync rounds let device-list updates and Megolm key sharing settle before
    // sending the custom event. This mirrors the existing encrypted text-message test.
    for _ in 0..6 {
        sync_pair_retry(&alice, &bob).await?;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    let (tx, mut rx) = mpsc::channel::<CustomEvent>(16);
    bob.on_custom_event("io.manymath.encrypted.test", move |ev| {
        let _ = tx.try_send(ev);
    });

    let mut observed_latencies = Vec::with_capacity(ENCRYPTED_CUSTOM_EVENT_LATENCY_SAMPLES);
    for sample in 0..ENCRYPTED_CUSTOM_EVENT_LATENCY_SAMPLES {
        let position_ms = 12000 + sample as i64;
        let sent_at = Instant::now();
        let event_id = alice
            .send_custom_event(
                &room_id,
                "io.manymath.encrypted.test",
                json!({ "action": "play", "position_ms": position_ms, "sample": sample }),
            )
            .await?;
        eprintln!("Alice sent encrypted custom event sample {sample}: {event_id}");

        sync_once_retry(&bob).await?;
        let event = tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .expect("encrypted custom event receive timed out")
            .expect("encrypted custom event channel closed unexpectedly");
        let observed_latency = sent_at.elapsed();
        eprintln!(
            "Encrypted custom event sample {sample} observed after {} ms",
            observed_latency.as_millis()
        );
        observed_latencies.push(observed_latency);

        assert_eq!(event.event_id, event_id);
        assert_eq!(event.room_id, room_id);
        assert_eq!(event.event_type, "io.manymath.encrypted.test");
        assert_eq!(event.content["action"], "play");
        assert_eq!(event.content["position_ms"].as_i64(), Some(position_ms));
        assert_eq!(event.content["sample"].as_u64(), Some(sample as u64));
        assert!(event.timestamp > 0);
    }

    let max_latency = observed_latencies
        .iter()
        .copied()
        .max()
        .expect("latency sample set should not be empty");
    let total_latency: Duration = observed_latencies.iter().copied().sum();
    let average_latency = total_latency / observed_latencies.len() as u32;
    eprintln!(
        "Encrypted custom event latency samples: count={} avg={} ms max={} ms",
        observed_latencies.len(),
        average_latency.as_millis(),
        max_latency.as_millis()
    );

    if enforces_local_media_latency_tolerance(kind) {
        assert!(
            max_latency <= LOCAL_MEDIA_CLOCK_CORRECTION_TOLERANCE,
            "max encrypted custom-event latency {} ms exceeded local_media tolerance {} ms",
            max_latency.as_millis(),
            LOCAL_MEDIA_CLOCK_CORRECTION_TOLERANCE.as_millis()
        );
    }

    Ok(())
}

test_harness::e2e_test!(custom_event_round_trip);
test_harness::e2e_test!(encrypted_custom_event_round_trip);
