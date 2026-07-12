use std::time::Duration;

use anyhow::{Context, Result};
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

async fn finalize_server(server: TestHomeserver, run_result: Result<()>) -> Result<()> {
    if let Err(stop_err) = server.stop().await {
        if run_result.is_ok() {
            return Err(stop_err);
        }

        eprintln!("failed to stop homeserver after test failure: {stop_err:#}");
    }

    run_result
}

/// Minimal valid 1x1 pixel PNG image (67 bytes).
/// Synapse only generates thumbnails for image MIME types, not text/plain.
#[allow(dead_code)]
const MINIMAL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk length + type
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1 pixels
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, // 8-bit RGB, CRC
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, // compressed pixel data
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, // CRC
    0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
    0x44, 0xAE, 0x42, 0x60, 0x82, // IEND CRC
];

/// Enable key backup, restore from a fresh client.
async fn key_backup_enable_and_restore(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        let alice_reg = server.register_user("alice_backup", "password1").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;
        alice.sync_once().await?;

        // Create an encrypted room
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Backup Test Room".into()),
                ..Default::default()
            })
            .await?;
        alice.enable_encryption(&room_id).await?;
        alice.sync_once().await?;

        // Enable recovery and get the recovery key
        let recovery_key = alice.enable_recovery().await?;
        assert!(!recovery_key.is_empty(), "recovery key should not be empty");
        eprintln!(
            "Recovery key obtained (first 8 chars): {}",
            &recovery_key[..8.min(recovery_key.len())]
        );

        // Send a message so there's something to back up
        alice.send_text(&room_id, "backup test message").await?;

        // Block until the just-created room key has actually finished
        // uploading to the server-side backup. Backup upload runs on a
        // background task that sync only *signals*; polling sync_once in a
        // loop races that task and can proceed before the key is backed up.
        alice.wait_for_backup_upload().await?;

        // Create a FRESH client for the same user with a new store
        let alice2_store = tempfile::tempdir()?;
        let alice2 = ManyMatrixClient::new(server.base_url(), alice2_store.path()).await?;
        let _session2 = alice2.login(&alice_reg.localpart, "password1").await?;
        alice2.sync_once().await?;

        // Restore key backup on the fresh client
        alice2.restore_key_backup(&recovery_key).await?;
        eprintln!(
            "Key backup restore succeeded with key: {}",
            &recovery_key[..8.min(recovery_key.len())]
        );

        // Prove the restored keys actually decrypt: a fresh device has no
        // Megolm session of its own for messages sent before it existed, so
        // fetching the historical message only comes back with the real body
        // (rather than an undecryptable ciphertext) if the backup restore
        // actually recovered a usable session key.
        let history = alice2.get_messages(&room_id, None, 10).await?;
        let restored_msg = history
            .messages
            .iter()
            .find(|m| m.body == "backup test message");
        assert!(
            restored_msg.is_some(),
            "restored client should decrypt the pre-existing message via the recovered \
             backup key; got bodies: {:?}",
            history.messages.iter().map(|m| &m.body).collect::<Vec<_>>()
        );
        eprintln!("Verified real decryption round-trip via restored key backup");

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

test_harness::e2e_test!(key_backup_enable_and_restore);

/// Upload media and download via mxc_uri, exact byte round-trip.
async fn media_download_round_trip(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        let alice_reg = server.register_user("alice_dl", "password1").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;
        alice.sync_once().await?;

        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Download Test Room".into()),
                ..Default::default()
            })
            .await?;
        alice.sync_once().await?;

        // Upload test data
        let test_data: Vec<u8> = b"media download round trip content".to_vec();
        let event_id = alice
            .upload_media(
                &room_id,
                "download_test.txt",
                "text/plain",
                test_data.clone(),
            )
            .await?;
        assert!(!event_id.is_empty(), "event_id should not be empty");
        eprintln!("Uploaded media, event_id: {}", event_id);

        alice.sync_once().await?;

        let messages = alice.get_messages(&room_id, None, 10).await?;

        // Find the media message by filename in body
        let media_msg = messages
            .messages
            .iter()
            .find(|m| m.body.contains("download_test.txt"));
        assert!(
            media_msg.is_some(),
            "Should see media message with filename. Got: {:?}",
            messages
                .messages
                .iter()
                .map(|m| &m.body)
                .collect::<Vec<_>>()
        );
        let media_msg = media_msg.unwrap();

        // mxc_uri must be populated for non-encrypted media
        assert!(
            media_msg.mxc_uri.is_some(),
            "mxc_uri should be populated for media message"
        );
        let mxc = media_msg.mxc_uri.as_ref().unwrap();
        eprintln!("mxc_uri: {}", mxc);

        // Download and verify bytes match exactly
        let downloaded = alice.download_media(mxc).await?;
        assert_eq!(
            downloaded, test_data,
            "downloaded content should match uploaded content"
        );
        eprintln!("Download round-trip verified: {} bytes", downloaded.len());

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

test_harness::e2e_test!(media_download_round_trip);

/// Upload a PNG and fetch its thumbnail.
async fn thumbnail_fetch_for_image(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        let alice_reg = server.register_user("alice_thumb", "password1").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _session = alice.login(&alice_reg.localpart, "password1").await?;
        alice.sync_once().await?;

        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Thumbnail Test Room".into()),
                ..Default::default()
            })
            .await?;
        alice.sync_once().await?;

        // Upload the minimal PNG image (must use image/png for Synapse thumbnails)
        let event_id = alice
            .upload_media(
                &room_id,
                "test_image.png",
                "image/png",
                MINIMAL_PNG.to_vec(),
            )
            .await?;
        assert!(!event_id.is_empty());
        eprintln!("Uploaded PNG image, event_id: {}", event_id);

        alice.sync_once().await?;

        let messages = alice.get_messages(&room_id, None, 10).await?;

        // Find the image message (upload_media with image/png sends as m.image)
        let img_msg = messages.messages.iter().find(|m| m.msgtype == "m.image");
        assert!(
            img_msg.is_some(),
            "Should see m.image message. Got: {:?}",
            messages
                .messages
                .iter()
                .map(|m| (&m.msgtype, &m.body))
                .collect::<Vec<_>>()
        );
        let img_msg = img_msg.unwrap();

        assert!(
            img_msg.mxc_uri.is_some(),
            "mxc_uri should be populated for image message"
        );
        let mxc = img_msg.mxc_uri.as_ref().unwrap();
        eprintln!("Image mxc_uri: {}", mxc);

        // Fetch thumbnail, Synapse generates thumbnails for image content types
        let thumb = alice.get_thumbnail(mxc, 64, 64).await?;
        assert!(!thumb.is_empty(), "thumbnail should not be empty");
        eprintln!("Thumbnail fetched: {} bytes", thumb.len());

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

test_harness::e2e_test!(thumbnail_fetch_for_image);

/// Upload media in an E2EE room, mxc_uri is None (encrypted source).
async fn encrypted_media_upload(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        let alice_reg = server.register_user("alice_emedia", "password1").await?;
        let bob_reg = server.register_user("bob_emedia", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates room with Bob invited
        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("Encrypted Media Test".into()),
                invite: vec![bob_reg.user_id.clone()],
                ..Default::default()
            })
            .await?;

        alice.sync_once().await?;
        bob.sync_once().await?;
        bob.join_room(&room_id).await?;

        alice.sync_once().await?;
        bob.sync_once().await?;

        // Enable E2EE
        alice.enable_encryption(&room_id).await?;

        // Multiple sync rounds for Megolm key exchange (same pattern as encryption.rs)
        for _ in 0..6 {
            alice.sync_once().await?;
            bob.sync_once().await?;
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        // Alice uploads media in the encrypted room
        let event_id = alice
            .upload_media(
                &room_id,
                "secret.txt",
                "text/plain",
                b"encrypted media content".to_vec(),
            )
            .await?;
        assert!(!event_id.is_empty(), "event_id should not be empty");
        eprintln!("Uploaded encrypted media, event_id: {}", event_id);

        alice.sync_once().await?;
        bob.sync_once().await?;

        // Bob retrieves messages
        let messages = bob.get_messages(&room_id, None, 10).await?;

        // Bob should see the encrypted media message
        let media_msg = messages
            .messages
            .iter()
            .find(|m| m.body.contains("secret.txt"));
        assert!(
            media_msg.is_some(),
            "Bob should see encrypted media message. Got: {:?}",
            messages
                .messages
                .iter()
                .map(|m| (&m.body, &m.mxc_uri))
                .collect::<Vec<_>>()
        );
        let media_msg = media_msg.unwrap();

        // Encrypted media has no plain MXC shortcut, but retains the complete
        // descriptor required by matrix-sdk to authenticate and decrypt it.
        assert!(
            media_msg.mxc_uri.is_none(),
            "mxc_uri should be None for encrypted media (MediaSource::Encrypted), got: {:?}",
            media_msg.mxc_uri
        );
        let media_source = media_msg
            .media_source
            .as_ref()
            .context("encrypted media should expose its complete media source")?;
        assert!(
            media_source.get("file").is_some(),
            "encrypted media source should contain a file descriptor: {media_source}"
        );
        let downloaded = bob.download_media_source(media_source).await?;
        assert_eq!(downloaded, b"encrypted media content");
        eprintln!("Encrypted media descriptor and decrypted download verified");

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

test_harness::e2e_test!(encrypted_media_upload);
