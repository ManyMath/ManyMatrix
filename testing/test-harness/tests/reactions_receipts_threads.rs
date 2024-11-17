#![cfg(feature = "docker-tests")]
use std::time::Duration;

use anyhow::Result;
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient, ReactionEvent, ReceiptEvent};
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

/// MSG-06: Reaction round-trip — Alice sends reaction, Bob receives via on_reaction callback.
#[tokio::test]
async fn reaction_round_trip() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());

    let _alice_reg = server.register_user("alice_react", "password1").await?;
    let _bob_reg = server.register_user("bob_react", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login("alice_react", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login("bob_react", "password2").await?;

    // Alice creates a room and invites Bob
    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Reaction Test Room".into()),
            invite: vec!["@bob_react:localhost".into()],
            ..Default::default()
        })
        .await?;

    // Initial syncs and Bob joins
    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Register on_reaction callback on Bob BEFORE sending (Fn, not async)
    let (tx, mut rx) = mpsc::channel::<ReactionEvent>(16);
    bob.on_reaction(move |ev| {
        let _ = tx.try_send(ev);
    });

    // Alice sends a message and gets the event ID
    let msg_event_id = alice.send_text(&room_id, "react to this").await?;
    eprintln!("Alice sent message: {}", msg_event_id);

    // Alice syncs so local state is updated before reaction
    alice.sync_once().await?;

    // Alice sends reaction (thumbs up)
    let _reaction_event_id = alice
        .send_reaction(&room_id, &msg_event_id, "\u{1F44D}")
        .await?;
    eprintln!("Alice sent reaction");

    alice.sync_once().await?;
    bob.sync_once().await?;

    // Wait for Bob to receive the reaction
    let reaction = tokio::time::timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("reaction receive timed out")
        .expect("reaction channel closed unexpectedly");

    eprintln!(
        "Bob received reaction: key={}, relates_to={}",
        reaction.key, reaction.relates_to_event_id
    );

    assert_eq!(
        reaction.key, "\u{1F44D}",
        "reaction key should be thumbs up emoji"
    );
    assert_eq!(
        reaction.relates_to_event_id, msg_event_id,
        "reaction should relate to the original message event"
    );

    Ok(())
}

/// MSG-08: Read receipt round-trip — Bob sends read receipt for Alice's message,
/// Alice receives via on_receipt callback with correct event ID and user ID.
#[tokio::test]
async fn read_receipt_round_trip() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());

    let _alice_reg = server.register_user("alice_rcpt", "password1").await?;
    let _bob_reg = server.register_user("bob_rcpt", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login("alice_rcpt", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login("bob_rcpt", "password2").await?;

    // Alice creates a room and invites Bob
    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Receipt Test Room".into()),
            invite: vec!["@bob_rcpt:localhost".into()],
            ..Default::default()
        })
        .await?;

    // Initial syncs and Bob joins
    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Register on_receipt callback on Alice BEFORE sending (Fn, not async)
    let (tx, mut rx) = mpsc::channel::<ReceiptEvent>(16);
    alice.on_receipt(move |ev| {
        let _ = tx.try_send(ev);
    });

    // Alice sends a message
    let msg_event_id = alice.send_text(&room_id, "please read this").await?;
    eprintln!("Alice sent message: {}", msg_event_id);

    // Alice syncs, Bob syncs so Bob has the message
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Bob sends read receipt for Alice's message
    bob.send_read_receipt(&room_id, &msg_event_id).await?;
    eprintln!("Bob sent read receipt");

    // Bob syncs, Alice syncs to propagate the ephemeral receipt event
    bob.sync_once().await?;

    // Retry loop: sync Alice up to 5 times, checking for receipt after each
    let mut receipt_opt = rx.try_recv().ok();
    for i in 0..5 {
        if receipt_opt.is_some() {
            break;
        }
        alice.sync_once().await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        receipt_opt = rx.try_recv().ok();
        eprintln!("Receipt retry {}: {:?}", i + 1, receipt_opt.is_some());
    }

    // Fall back to async timeout if still not received
    let receipt = if let Some(r) = receipt_opt {
        r
    } else {
        tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("read receipt receive timed out — on_receipt may not fire for ephemeral events via sync_once")
            .expect("receipt channel closed unexpectedly")
    };

    eprintln!(
        "Alice received receipt: event_id={}, user_id={}",
        receipt.event_id, receipt.user_id
    );

    assert_eq!(
        receipt.event_id, msg_event_id,
        "receipt should be for the original message"
    );
    assert!(
        receipt.user_id.contains("bob_rcpt"),
        "receipt should be from bob_rcpt, got: {}",
        receipt.user_id
    );

    Ok(())
}

/// MSG-11: Threaded message round-trip — Alice sends thread reply, Bob sees it
/// via get_messages with thread_root populated.
#[tokio::test]
async fn threaded_message_round_trip() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());

    let _alice_reg = server.register_user("alice_thread", "password1").await?;
    let _bob_reg = server.register_user("bob_thread", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login("alice_thread", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login("bob_thread", "password2").await?;

    // Alice creates a room and invites Bob
    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Thread Test Room".into()),
            invite: vec!["@bob_thread:localhost".into()],
            ..Default::default()
        })
        .await?;

    // Initial syncs and Bob joins
    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Alice sends the thread root message
    let root_event_id = alice.send_text(&room_id, "thread root message").await?;
    eprintln!("Alice sent thread root: {}", root_event_id);

    // Alice syncs so local state is updated
    alice.sync_once().await?;

    // Alice sends a thread reply
    let _reply_event_id = alice
        .send_thread_reply(&room_id, &root_event_id, "thread reply body")
        .await?;
    eprintln!("Alice sent thread reply");

    // Both sync to propagate events
    alice.sync_once().await?;
    bob.sync_once().await?;

    // Bob reads messages via pagination
    let messages = bob.get_messages(&room_id, None, 20).await?;
    eprintln!(
        "Bob sees {} messages: {:?}",
        messages.messages.len(),
        messages
            .messages
            .iter()
            .map(|m| (&m.body, &m.thread_root))
            .collect::<Vec<_>>()
    );

    // Find the thread reply
    let thread_reply = messages
        .messages
        .iter()
        .find(|m| m.body.contains("thread reply body"));

    assert!(
        thread_reply.is_some(),
        "Bob should see the thread reply in get_messages. Got messages: {:?}",
        messages
            .messages
            .iter()
            .map(|m| &m.body)
            .collect::<Vec<_>>()
    );

    let thread_reply = thread_reply.unwrap();
    assert_eq!(
        thread_reply.thread_root.as_deref(),
        Some(root_event_id.as_str()),
        "thread reply should have thread_root set to the root event ID"
    );

    eprintln!(
        "Thread reply verified: thread_root={:?}",
        thread_reply.thread_root
    );

    Ok(())
}
