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

/// Reaction round-trip: Alice sends a reaction, Bob receives it via on_reaction.
async fn reaction_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

        let alice_reg = server.register_user("alice_react", "password1").await?;
        let bob_reg = server.register_user("bob_react", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates a room and invites Bob
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Reaction Test Room".into()),
                invite: vec![bob_reg.user_id.clone()],
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
    .await;
    server.finish(run_result).await
}

/// Read receipt round-trip: Bob sends a read receipt, Alice receives it via on_receipt.
async fn read_receipt_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

        let alice_reg = server.register_user("alice_rcpt", "password1").await?;
        let bob_reg = server.register_user("bob_rcpt", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates a room and invites Bob
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Receipt Test Room".into()),
                invite: vec![bob_reg.user_id.clone()],
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
                .expect("read receipt receive timed out, on_receipt may not fire for ephemeral events via sync_once")
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
            receipt.user_id.contains(bob_reg.localpart.as_str()),
            "receipt should be from bob_rcpt, got: {}",
            receipt.user_id
        );
        assert_eq!(
            receipt.thread_id.as_deref(),
            Some("main"),
            "ordinary room receipts should preserve their explicit main scope"
        );

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

/// Threaded message round-trip: Alice sends a thread reply, Bob reads it via get_messages.
async fn threaded_message_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

        let alice_reg = server.register_user("alice_thread", "password1").await?;
        let bob_reg = server.register_user("bob_thread", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates a room and invites Bob
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Thread Test Room".into()),
                invite: vec![bob_reg.user_id.clone()],
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
        let reply_event_id = alice
            .send_thread_reply(
                &room_id,
                &root_event_id,
                &root_event_id,
                "thread reply body",
            )
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

        // The dedicated relations path must return the authoritative root and
        // replies without relying on whatever room-history page the UI loaded.
        let thread_page = bob
            .get_thread_messages(&room_id, &root_event_id, None, 20)
            .await?;
        assert_eq!(thread_page.root.event_id, root_event_id);
        assert_eq!(thread_page.messages.len(), 1);
        assert_eq!(thread_page.messages[0].event_id, reply_event_id);
        assert_eq!(
            thread_page.messages[0].thread_root.as_deref(),
            Some(root_event_id.as_str())
        );

        // Opening the room advances only its explicit `main` receipt. It must not
        // consume the unread notification belonging to this thread.
        bob.send_read_receipt(&room_id, &root_event_id).await?;

        // `/threads` is not implemented by every homeserver in the compatibility
        // matrix. Synapse and supporting servers must expose the bundled count;
        // known non-Synapse variants may skip only this capability assertion.
        let index = match bob.thread_index(20).await {
            Ok(index) => index,
            Err(error) if !kind.slug().contains("synapse") => {
                bob.send_thread_read_receipt(&room_id, &root_event_id, &reply_event_id)
                    .await?;
                eprintln!(
                    "{} does not expose the Matrix thread index; relations and scoped receipt passed: {error}",
                    kind.slug()
                );
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };
        let summary = index
            .iter()
            .find(|thread| thread.room_id == room_id && thread.root.event_id == root_event_id)
            .expect("thread index should include the new root");
        assert_eq!(summary.reply_count, 1);
        assert_eq!(
            summary
                .latest_reply
                .as_ref()
                .map(|reply| reply.event_id.as_str()),
            Some(reply_event_id.as_str())
        );
        if kind.slug().contains("synapse") {
            assert!(
                summary.unread_count.unwrap_or(0) > 0,
                "Synapse should map the unread thread notification to its root"
            );
        }

        // A thread-aware client advances a receipt scoped to this root rather than
        // accidentally clearing the room's main timeline.
        bob.send_thread_read_receipt(&room_id, &root_event_id, &reply_event_id)
            .await?;

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(reaction_round_trip);
test_harness::e2e_test!(read_receipt_round_trip);
test_harness::e2e_test!(threaded_message_round_trip);
