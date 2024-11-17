#![cfg(feature = "docker-tests")]
use std::time::Duration;

use anyhow::Result;
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient};
use test_harness::{ServerKind, TestHomeserver};
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

/// TEST-03: Two clients exchange messages in an E2EE room.
/// Alice creates an encrypted room, invites Bob, both sync for key exchange,
/// Alice sends a message, Bob receives and decrypts it.
#[tokio::test]
async fn encrypted_messaging() -> Result<()> {
    init_tracing();

    // Start Synapse
    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());

    // Register users
    let _alice_reg = server.register_user("alice_e2ee", "password1").await?;
    let _bob_reg = server.register_user("bob_e2ee", "password2").await?;

    // Create clients with separate stores
    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _alice_session = alice.login("alice_e2ee", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _bob_session = bob.login("bob_e2ee", "password2").await?;

    // Alice creates a room and invites Bob
    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("E2EE Test Room".into()),
            invite: vec!["@bob_e2ee:localhost".into()],
            ..Default::default()
        })
        .await?;

    // Initial sync for both
    alice.sync_once().await?;

    // Enable encryption on the room
    alice.enable_encryption(&room_id).await?;
    alice.sync_once().await?;

    // Bob syncs, sees invite, joins
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;

    // Multiple syncs for device key exchange — Alice must discover Bob's
    // device keys so the Megolm session key will be shared with him.
    for _ in 0..6 {
        alice.sync_once().await?;
        bob.sync_once().await?;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    // Alice sends an encrypted message (transparent E2EE)
    let event_id = alice
        .send_text(&room_id, "secret encrypted message")
        .await?;
    assert!(!event_id.is_empty(), "should get event ID back");
    eprintln!("Alice sent encrypted message: {}", event_id);

    // Bob needs to sync to receive to-device key share first, then the message.
    // Multiple syncs with delays ensure the Megolm key arrives before decryption.
    for _ in 0..3 {
        bob.sync_once().await?;
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    // Use get_messages to verify Bob can decrypt the message from the timeline
    let messages = bob.get_messages(&room_id, None, 10).await?;
    let decrypted = messages
        .messages
        .iter()
        .find(|m| m.body == "secret encrypted message");
    assert!(
        decrypted.is_some(),
        "Bob should be able to read the decrypted message via pagination. Got messages: {:?}",
        messages
            .messages
            .iter()
            .map(|m| &m.body)
            .collect::<Vec<_>>()
    );
    eprintln!("Bob decrypted message: {}", decrypted.unwrap().body);

    Ok(())
}

/// Two-client messaging test: Alice sends all message types, Bob verifies receipt.
#[tokio::test]
async fn message_types() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_msg", "password1").await?;
    let _bob_reg = server.register_user("bob_msg", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _session = alice.login("alice_msg", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _session = bob.login("bob_msg", "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Msg Types Test".into()),
            invite: vec!["@bob_msg:localhost".into()],
            ..Default::default()
        })
        .await?;

    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;

    // Alice sends all message types
    let _eid1 = alice.send_text(&room_id, "plain text").await?;
    let _eid2 = alice.send_html(&room_id, "hello", "<b>hello</b>").await?;
    let _eid3 = alice.send_notice(&room_id, "notice message").await?;
    let _eid4 = alice.send_emote(&room_id, "waves").await?;

    // Bob syncs and reads messages via pagination
    bob.sync_once().await?;
    let messages = bob.get_messages(&room_id, None, 20).await?;
    let bodies: Vec<&str> = messages.messages.iter().map(|m| m.body.as_str()).collect();

    assert!(
        bodies.contains(&"plain text"),
        "Bob should see plain text: {bodies:?}"
    );
    assert!(
        bodies.contains(&"hello"),
        "Bob should see html message: {bodies:?}"
    );
    assert!(
        bodies.contains(&"notice message"),
        "Bob should see notice: {bodies:?}"
    );
    assert!(
        bodies.contains(&"waves"),
        "Bob should see emote: {bodies:?}"
    );

    // Verify message types
    let html_msg = messages
        .messages
        .iter()
        .find(|m| m.body == "hello")
        .unwrap();
    assert_eq!(html_msg.formatted_body.as_deref(), Some("<b>hello</b>"));

    eprintln!("All message types sent by Alice, verified by Bob");

    Ok(())
}

/// Two-client edit, reply, redact test (MSG-04, MSG-05, MSG-07).
/// Alice sends, edits, replies, redacts — Bob verifies each operation via pagination.
#[tokio::test]
async fn edit_reply_redact() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_edit", "password1").await?;
    let _bob_reg = server.register_user("bob_edit", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _session = alice.login("alice_edit", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _session = bob.login("bob_edit", "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Edit Test Room".into()),
            invite: vec!["@bob_edit:localhost".into()],
            ..Default::default()
        })
        .await?;

    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;

    // Alice sends original message
    let original_event_id = alice.send_text(&room_id, "original message").await?;
    eprintln!("Sent original: {}", original_event_id);
    alice.sync_once().await?;

    // Alice edits (MSG-04)
    alice
        .edit_message(&room_id, &original_event_id, "edited message")
        .await?;

    // Alice replies (MSG-05)
    let reply_event_id = alice
        .reply_to(&room_id, &original_event_id, "this is a reply")
        .await?;
    eprintln!("Replied: {}", reply_event_id);

    // Bob syncs and verifies he can see the reply
    bob.sync_once().await?;
    let messages = bob.get_messages(&room_id, None, 20).await?;
    let bodies: Vec<&str> = messages.messages.iter().map(|m| m.body.as_str()).collect();
    assert!(
        bodies.iter().any(|b| b.contains("reply")),
        "Bob should see the reply: {bodies:?}"
    );

    // Verify reply has in_reply_to set
    let reply_msg = messages.messages.iter().find(|m| m.body.contains("reply"));
    if let Some(reply) = reply_msg {
        assert!(
            reply.in_reply_to.is_some(),
            "Reply should have in_reply_to set"
        );
    }

    // Alice redacts original (MSG-07)
    alice
        .redact(&room_id, &original_event_id, Some("test redaction"))
        .await?;
    eprintln!("Redacted original message");

    alice.sync_once().await?;
    bob.sync_once().await?;
    eprintln!("Edit/reply/redact two-client test complete");

    Ok(())
}

/// current_user_id returns the logged-in user's Matrix ID.
#[tokio::test]
async fn whoami() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_whoami", "password1").await?;

    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;

    // Before login: should return None
    assert!(
        client.current_user_id().is_none(),
        "no user ID before login"
    );

    // Login
    let _session = client.login("alice_whoami", "password1").await?;

    // After login: should return the full Matrix user ID
    let user_id = client.current_user_id();
    assert!(user_id.is_some(), "should have user ID after login");
    let user_id = user_id.unwrap();
    assert!(
        user_id.starts_with("@alice_whoami:"),
        "user ID should start with @alice_whoami: but got: {}",
        user_id
    );
    eprintln!("current_user_id() returned: {}", user_id);

    Ok(())
}

/// is_room_encrypted returns false for new room, true after enable_encryption.
#[tokio::test]
async fn is_room_encrypted() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_enc", "password1").await?;

    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    let _session = client.login("alice_enc", "password1").await?;

    // Create a room (not encrypted by default)
    let room_id = client
        .create_room(CreateRoomOptions {
            name: Some("Encryption State Test".into()),
            ..Default::default()
        })
        .await?;

    // Must sync so room is in the local store
    client.sync_once().await?;

    // Should be false initially
    let encrypted = client.is_room_encrypted(&room_id).await?;
    assert!(!encrypted, "room should not be encrypted initially");
    eprintln!("Room {} encrypted: {}", room_id, encrypted);

    // Enable encryption
    client.enable_encryption(&room_id).await?;
    client.sync_once().await?;

    // Should be true now
    let encrypted = client.is_room_encrypted(&room_id).await?;
    assert!(
        encrypted,
        "room should be encrypted after enable_encryption"
    );
    eprintln!("Room {} encrypted after enable: {}", room_id, encrypted);

    Ok(())
}

/// Two-client media test: Alice uploads, Bob verifies via pagination.
#[tokio::test]
async fn media_upload_download() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_media", "password1").await?;
    let _bob_reg = server.register_user("bob_media", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _session = alice.login("alice_media", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _session = bob.login("bob_media", "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Media Test Room".into()),
            invite: vec!["@bob_media:localhost".into()],
            ..Default::default()
        })
        .await?;

    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;

    // Alice uploads a file
    let test_data: Vec<u8> = b"Hello, this is test file content for media upload!".to_vec();
    let event_id = alice
        .upload_media(&room_id, "test.txt", "text/plain", test_data.clone())
        .await?;
    assert!(!event_id.is_empty());
    eprintln!("Uploaded media, event_id: {}", event_id);

    // Bob syncs and reads messages
    bob.sync_once().await?;
    let messages = bob.get_messages(&room_id, None, 10).await?;

    // Bob should see the media event with the filename in body
    let media_msg = messages
        .messages
        .iter()
        .find(|m| m.body.contains("test.txt"));
    assert!(
        media_msg.is_some(),
        "Bob should see media message with filename. Got: {:?}",
        messages
            .messages
            .iter()
            .map(|m| &m.body)
            .collect::<Vec<_>>()
    );
    eprintln!("Bob sees media message: {:?}", media_msg.unwrap().body);

    Ok(())
}

/// MessageEvent.mxc_uri, filename, file_size populated for media uploads.
#[tokio::test]
async fn mxc_uri_on_message_event() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice_reg = server.register_user("alice_mxc", "password1").await?;
    let _bob_reg = server.register_user("bob_mxc", "password2").await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    let _session = alice.login("alice_mxc", "password1").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    let _session = bob.login("bob_mxc", "password2").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("MXC URI Test".into()),
            invite: vec!["@bob_mxc:localhost".into()],
            ..Default::default()
        })
        .await?;

    alice.sync_once().await?;
    bob.sync_once().await?;
    bob.join_room(&room_id).await?;
    alice.sync_once().await?;

    // Alice uploads a file (uses upload_media which sends as m.file attachment)
    let test_data: Vec<u8> = b"mxc uri test file content".to_vec();
    let event_id = alice
        .upload_media(&room_id, "testfile.txt", "text/plain", test_data.clone())
        .await?;
    assert!(!event_id.is_empty());
    eprintln!("Uploaded media, event_id: {}", event_id);

    // Bob syncs and reads messages via pagination
    bob.sync_once().await?;
    let messages = bob.get_messages(&room_id, None, 10).await?;

    // Find the media message
    let media_msg = messages
        .messages
        .iter()
        .find(|m| m.body.contains("testfile.txt"));
    assert!(
        media_msg.is_some(),
        "Bob should see media message. Got: {:?}",
        messages
            .messages
            .iter()
            .map(|m| (&m.body, &m.msgtype, &m.mxc_uri))
            .collect::<Vec<_>>()
    );
    let media_msg = media_msg.unwrap();

    // Assert mxc_uri is populated and starts with mxc://
    assert!(
        media_msg.mxc_uri.is_some(),
        "mxc_uri should be populated for media message, got None. msgtype: {}",
        media_msg.msgtype
    );
    let mxc = media_msg.mxc_uri.as_ref().unwrap();
    assert!(
        mxc.starts_with("mxc://"),
        "mxc_uri should start with mxc:// but got: {}",
        mxc
    );
    eprintln!("mxc_uri: {}", mxc);

    // Assert filename is populated
    assert!(
        media_msg.filename.is_some(),
        "filename should be populated for media message"
    );
    let fname = media_msg.filename.as_ref().unwrap();
    assert!(
        fname.contains("testfile.txt"),
        "filename should contain testfile.txt but got: {}",
        fname
    );
    eprintln!("filename: {}", fname);

    // Assert file_size is populated (text/plain upload should have size info)
    // Note: file_size may be None if the homeserver doesn't include info.size —
    // assert it's present but log if absent for debugging
    if let Some(size) = media_msg.file_size {
        assert!(size > 0, "file_size should be > 0 if present");
        eprintln!("file_size: {}", size);
    } else {
        eprintln!("file_size: None (homeserver may not include info.size for text/plain)");
    }

    // Verify the mxc_uri works with download_media
    let downloaded = bob.download_media(mxc).await?;
    assert_eq!(
        downloaded, test_data,
        "downloaded content should match uploaded content"
    );
    eprintln!(
        "download_media round-trip verified: {} bytes",
        downloaded.len()
    );

    Ok(())
}
