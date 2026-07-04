use std::time::Duration;

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

test_harness::e2e_test!(custom_event_round_trip);
