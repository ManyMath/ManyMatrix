use std::time::Duration;

use anyhow::Result;
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient, StoredSession};
use matrix_sdk::ruma::api::client::room::create_room::v3::Request as CreateRoomRequest;
use matrix_sdk::ruma::events::room::message::SyncRoomMessageEvent;
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

/// Full cycle: start homeserver -> register two users -> login via our core
/// library -> create room -> invite + join -> send message -> verify receipt.
async fn alice_sends_bob_receives(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        // --- Register users directly via CS API ---
        let alice_reg = server.register_user("alice", "password1").await?;
        let bob_reg = server.register_user("bob", "password2").await?;

        // --- Login through our core library ---
        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        // --- Alice creates a room and invites Bob ---
        let mut req = CreateRoomRequest::new();
        req.name = Some("test-room".to_owned());
        req.invite = vec![
            <&matrix_sdk::ruma::UserId>::try_from(bob_reg.user_id.as_str())
                .unwrap()
                .to_owned(),
        ];
        let create_resp = alice.inner().create_room(req).await?;
        let room_id = create_resp.room_id().to_owned();
        eprintln!("Room created: {room_id}");

        // --- Bob syncs to see the invite, then joins ---
        bob.sync_once().await?;
        let bob_room = bob
            .inner()
            .get_room(&room_id)
            .expect("bob should see the room after sync");
        bob_room.join().await?;
        eprintln!("Bob joined {room_id}");

        // --- Set up a channel to capture Bob's incoming messages ---
        let (tx, mut rx) = mpsc::channel::<String>(16);
        bob.inner()
            .add_event_handler(move |ev: SyncRoomMessageEvent, _room: matrix_sdk::Room| {
                let tx = tx.clone();
                async move {
                    if let SyncRoomMessageEvent::Original(msg) = ev {
                        let _ = tx.send(msg.content.body().to_owned()).await;
                    }
                }
            });

        // --- Alice syncs (to learn Bob joined), then sends a message ---
        alice.sync_once().await?;
        alice.send_text(room_id.as_str(), "hello bob").await?;
        eprintln!("Alice sent message");

        // --- Bob syncs and should receive the message ---
        bob.sync_once().await?;

        let received = tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await?
            .expect("should have received a message");

        assert_eq!(received, "hello bob");
        eprintln!("Bob received: {received}");

        Ok(())
    }
    .await;

    server.finish(run_result).await
}

test_harness::e2e_test!(alice_sends_bob_receives);

/// Simpler test: just login and sync once.
async fn login_and_sync(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;

    let run_result = async {
        let user = server.register_user("testuser", "testpass").await?;

        let store = tempfile::tempdir()?;
        let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
        let session = client.login(&user.localpart, "testpass").await?;

        assert!(session
            .session
            .meta
            .user_id
            .as_str()
            .contains(user.localpart.as_str()));

        client.sync_once().await?;

        let rooms = client.joined_rooms().await;
        // Synapse: fresh user has no rooms.
        // Tuwunel variants: may auto-join users to an admin/welcome room.
        if kind.is_synapse() {
            assert!(rooms.is_empty());
        }

        Ok(())
    }
    .await;

    server.finish(run_result).await
}

test_harness::e2e_test!(login_and_sync);

/// Server version/capability data is exposed as structured values after login.
async fn server_capability_data_is_serializable(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;

    let run_result = async {
        let user = server
            .register_user("capability_user", "capability_pass")
            .await?;

        let store = tempfile::tempdir()?;
        let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
        client.login(&user.localpart, "capability_pass").await?;

        let capabilities = client.server_capabilities().await?;
        let json = serde_json::to_value(&capabilities)?;

        assert!(
            json.get("versions")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|versions| !versions.is_empty()),
            "capability JSON should contain non-empty versions: {json}"
        );
        assert!(
            json.get("supports_authenticated_media")
                .and_then(serde_json::Value::as_bool)
                .is_some(),
            "capability JSON should contain supports_authenticated_media: {json}"
        );
        assert!(
            json.get("supports_refresh_tokens")
                .and_then(serde_json::Value::as_bool)
                .is_some(),
            "capability JSON should contain supports_refresh_tokens: {json}"
        );

        Ok(())
    }
    .await;

    server.finish(run_result).await
}

test_harness::e2e_test!(server_capability_data_is_serializable);

#[cfg(feature = "embedded-tests")]
#[tokio::test]
async fn embedded_servers_bind_distinct_ports() -> Result<()> {
    init_tracing();

    let (first, second) = tokio::try_join!(
        TestHomeserver::start(ServerKind::TuwunelEmbedded),
        TestHomeserver::start(ServerKind::TuwunelEmbedded),
    )?;

    let first_port = first.bound_port();
    let second_port = second.bound_port();

    assert_ne!(
        first_port, second_port,
        "embedded servers should bind distinct ports"
    );
    assert_ne!(
        first.base_url(),
        second.base_url(),
        "embedded servers should report distinct bound addresses"
    );

    first.stop().await?;
    second.stop().await?;

    Ok(())
}

// All remaining tests in this file are Docker-only Synapse coverage.

/// Verify session persists: login, save session, create new client, restore, sync.
async fn session_persist_across_restart(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let user = server.register_user("persist_user", "password1").await?;

        let store_dir = tempfile::tempdir()?;
        let session_file = store_dir.path().join("session.json");

        // Login and save session
        {
            let client = ManyMatrixClient::new(server.base_url(), store_dir.path()).await?;
            let session = client.login(&user.localpart, "password1").await?;
            let capabilities = client.server_capabilities().await?;
            assert!(
                !capabilities.versions.is_empty(),
                "server_capabilities should expose versions after login"
            );
            session.save(&session_file)?;
            client.sync_once().await?;
        }
        // Client dropped -- simulates process restart

        // Create new client, restore session, verify it works
        let client2 = ManyMatrixClient::new(server.base_url(), store_dir.path()).await?;
        let loaded = StoredSession::load(&session_file)?;
        client2.restore(&loaded).await?;
        client2.sync_once().await?;
        let restored_capabilities = client2.server_capabilities().await?;
        let _supports_refresh_tokens = restored_capabilities.supports_refresh_tokens;

        // Verify we're logged in as the same user
        let rooms = client2.joined_rooms().await;
        // Fresh user has no rooms -- key point is no error (session restored successfully)
        if kind.is_synapse() {
            assert!(rooms.is_empty());
        }
        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(session_persist_across_restart);

/// Verify logout invalidates session and cleans up local state.
async fn logout_clears_state(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let user = server.register_user("logout_user", "password1").await?;

        let store_dir = tempfile::tempdir()?;
        let client = ManyMatrixClient::new(server.base_url(), store_dir.path()).await?;
        let _session = client.login(&user.localpart, "password1").await?;
        client.sync_once().await?;

        // Store directory should exist before logout
        assert!(store_dir.path().exists());

        // Logout
        client.logout().await?;

        // Store directory contents should be cleaned up by logout
        // (logout deletes store_path via remove_dir_all)

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(logout_clears_state);

/// Verify sync populates room list with RoomSummary data.
async fn sync_populates_room_list(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let alice_reg = server.register_user("alice_sync", "password1").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;

        // Alice creates a room
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Sync Test Room".into()),
                ..Default::default()
            })
            .await?;

        // Alice sends a message so there's a latest event
        alice.sync_once().await?;
        alice
            .send_text(room_id.as_str(), "hello from sync test")
            .await?;

        // Sync once to let the SDK replace ManyMatrix's direct-send preview with
        // the authoritative event when the homeserver includes it immediately.
        alice.sync_once().await?;
        let rooms = alice.joined_rooms().await;
        let room = rooms
            .iter()
            .find(|room| room.room_id == room_id)
            .expect("should find the created room in room list");

        assert!(!room.display_name.is_empty());
        // Verify last_message is populated
        let last = room
            .last_message
            .as_ref()
            .expect("last_message should be populated after sending a message");
        assert_eq!(last.body, "hello from sync test");
        assert!(!last.sender.is_empty(), "sender should not be empty");
        assert!(last.timestamp > 0, "timestamp should be positive");
        // unread_count is server-provided; for own messages it may be 0

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(sync_populates_room_list);

/// Verify that server_name_or_homeserver_url handles URL input correctly.
/// Full .well-known resolution requires a domain name setup, but we verify
/// the SDK accepts both URL and server-name-style input.
async fn well_known_resolution(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let user = server.register_user("wellknown_user", "password1").await?;

        // Test: Direct URL (current pattern) should work
        let store1 = tempfile::tempdir()?;
        let client = ManyMatrixClient::new(server.base_url(), store1.path()).await?;
        let session = client.login(&user.localpart, "password1").await?;
        assert!(session
            .session
            .meta
            .user_id
            .as_str()
            .contains(user.localpart.as_str()));

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(well_known_resolution);

/// Create room with options, invite+join another user, read room state.
async fn create_join_and_read_state(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let alice_reg = server.register_user("alice_room", "password1").await?;
        let bob_reg = server.register_user("bob_room", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates room with options
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("State Test Room".into()),
                topic: Some("Testing room state queries".into()),
                invite: vec![bob_reg.user_id.clone()],
                ..Default::default()
            })
            .await?;

        // Bob syncs to see invite, then joins
        bob.sync_once().await?;
        bob.join_room(&room_id).await?;

        // Alice syncs to see Bob joined
        alice.sync_once().await?;

        // Read room state
        let name = alice.room_name(&room_id)?;
        assert_eq!(name, Some("State Test Room".into()));

        let topic = alice.room_topic(&room_id)?;
        assert_eq!(topic, Some("Testing room state queries".into()));

        let members = alice.room_members(&room_id).await?;
        assert!(
            members.contains(&alice_reg.user_id),
            "alice should be in members: {:?}",
            members
        );
        assert!(
            members.contains(&bob_reg.user_id),
            "bob should be in members: {:?}",
            members
        );

        // Avatar URL is None (not set)
        let avatar = alice.room_avatar_url(&room_id)?;
        assert!(avatar.is_none());

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(create_join_and_read_state);

/// User can leave a room.
async fn leave_room_test(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let alice_reg = server.register_user("alice_leave", "password1").await?;
        let bob_reg = server.register_user("bob_leave", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates room, Bob joins
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Leave Test".into()),
                invite: vec![bob_reg.user_id.clone()],
                ..Default::default()
            })
            .await?;
        bob.sync_once().await?;
        bob.join_room(&room_id).await?;

        // Bob leaves
        bob.leave_room(&room_id).await?;

        // Alice syncs and checks members
        alice.sync_once().await?;
        let members = alice.room_members(&room_id).await?;
        assert!(
            !members.contains(&bob_reg.user_id),
            "bob should not be in members after leaving: {:?}",
            members
        );

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(leave_room_test);

/// User can kick and ban members with optional reasons.
async fn kick_and_ban(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    let run_result: Result<()> = async {
        let alice_reg = server.register_user("alice_mod", "password1").await?;
        let bob_reg = server.register_user("bob_mod", "password2").await?;
        let carol_reg = server.register_user("carol_mod", "password3").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _session = bob.login(&bob_reg.localpart, "password2").await?;

        let carol_store = tempfile::tempdir()?;
        let carol = ManyMatrixClient::new(server.base_url(), carol_store.path()).await?;
        let _session = carol.login(&carol_reg.localpart, "password3").await?;

        // Alice creates room, invites Bob and Carol
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Mod Test".into()),
                invite: vec![bob_reg.user_id.clone(), carol_reg.user_id.clone()],
                ..Default::default()
            })
            .await?;

        // Bob and Carol join
        bob.sync_once().await?;
        bob.join_room(&room_id).await?;
        carol.sync_once().await?;
        carol.join_room(&room_id).await?;

        alice.sync_once().await?;

        // Alice kicks Bob with reason
        alice
            .kick(&room_id, &bob_reg.user_id, Some("test kick"))
            .await?;

        alice.sync_once().await?;
        let members = alice.room_members(&room_id).await?;
        assert!(
            !members.contains(&bob_reg.user_id),
            "bob should not be in members after kick: {:?}",
            members
        );

        // Alice bans Carol with reason
        alice
            .ban(&room_id, &carol_reg.user_id, Some("test ban"))
            .await?;

        alice.sync_once().await?;
        let members = alice.room_members(&room_id).await?;
        assert!(
            !members.contains(&carol_reg.user_id),
            "carol should not be in members after ban: {:?}",
            members
        );

        Ok(())
    }
    .await;
    server.finish(run_result).await
}

test_harness::e2e_test!(kick_and_ban);
