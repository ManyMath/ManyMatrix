use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient};
use test_harness::compat::{
    build_server_report, default_report_path, write_json_report, BehaviorResult, BehaviorStatus,
    CompatibilityReport, ServerCompatibilityReport,
};
use test_harness::{ServerKind, TestHomeserver};
use tracing_subscriber::EnvFilter;

const REQUIRED_BEHAVIORS: [&str; 8] = [
    "auth",
    "capabilities",
    "sync",
    "rooms",
    "messaging",
    "media",
    "e2ee",
    "ffi_smoke",
];
const SYNC_TIMEOUT: Duration = Duration::from_secs(1);

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

#[tokio::test]
async fn compatibility_report() -> Result<()> {
    init_tracing();

    let mut server_reports = Vec::new();
    for kind in compiled_server_kinds() {
        let server = TestHomeserver::start(kind).await?;
        let behaviors = run_behavior_matrix(&server).await;
        let report = build_server_report(&server, behaviors).await;
        server.stop().await?;
        server_reports.push(report);
    }

    let report = CompatibilityReport::new(server_reports);
    assert_report_invariants(&report);

    let path = default_report_path();
    write_json_report(&report, &path)?;
    assert!(
        path_has_target_compat(&path),
        "report should be written under target/compat, got {}",
        path.display()
    );

    Ok(())
}

#[allow(clippy::vec_init_then_push)]
fn compiled_server_kinds() -> Vec<ServerKind> {
    let mut kinds = Vec::new();

    #[cfg(feature = "embedded-tests")]
    kinds.push(ServerKind::TuwunelEmbedded);
    #[cfg(feature = "docker-tests")]
    kinds.push(ServerKind::Synapse);
    #[cfg(feature = "docker-tests")]
    kinds.push(ServerKind::TuwunelDocker);
    #[cfg(feature = "docker-tests")]
    kinds.push(ServerKind::ContinuwuityDocker);
    #[cfg(feature = "docker-tests")]
    kinds.push(ServerKind::DendriteDocker);
    #[cfg(feature = "hosted-tests")]
    kinds.push(ServerKind::HostedSynapse);
    #[cfg(feature = "hosted-tests")]
    kinds.push(ServerKind::HostedTuwunel);

    kinds
}

async fn run_behavior_matrix(server: &TestHomeserver) -> Vec<BehaviorResult> {
    vec![
        capture_behavior("auth", || auth_behavior(server)).await,
        capture_behavior("capabilities", || capabilities_behavior(server)).await,
        capture_behavior("sync", || sync_behavior(server)).await,
        capture_behavior("rooms", || rooms_behavior(server)).await,
        capture_behavior("messaging", || messaging_behavior(server)).await,
        capture_behavior("media", || media_behavior(server)).await,
        capture_behavior("e2ee", || e2ee_behavior(server)).await,
        capture_behavior("ffi_smoke", || ffi_smoke_behavior(server)).await,
    ]
}

async fn capture_behavior<F, Fut>(behavior: &'static str, run: F) -> BehaviorResult
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<String>>,
{
    match run().await {
        Ok(details) => BehaviorResult::pass(behavior, details),
        Err(error) => BehaviorResult::fail(behavior, format!("{error:#}")),
    }
}

async fn capabilities_behavior(server: &TestHomeserver) -> Result<String> {
    let user = server
        .register_user("compat_caps", "compat_caps_pass")
        .await?;
    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    client.login(&user.localpart, "compat_caps_pass").await?;

    let capabilities = client.server_capabilities().await?;
    if capabilities.versions.is_empty() {
        bail!("server_capabilities returned no Matrix versions");
    }

    Ok(format!(
        "capability probe read versions={:?}, capabilities_authenticated={}, supports_authenticated_media={}, supports_refresh_tokens={}",
        capabilities.versions,
        capabilities.capabilities_authenticated,
        capabilities.supports_authenticated_media,
        capabilities.supports_refresh_tokens
    ))
}

async fn auth_behavior(server: &TestHomeserver) -> Result<String> {
    let user = server
        .register_user("compat_auth", "compat_auth_pass")
        .await?;
    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    let session = client.login(&user.localpart, "compat_auth_pass").await?;
    let refresh_token_status = if session.session.tokens.refresh_token.is_some() {
        "refresh-token returned"
    } else {
        "refresh-token gracefully absent"
    };

    if !session
        .session
        .meta
        .user_id
        .as_str()
        .contains(user.localpart.as_str())
    {
        bail!("login returned unexpected user ID");
    }

    Ok(format!(
        "registered and logged in through ManyMatrixClient; {refresh_token_status}"
    ))
}

async fn sync_behavior(server: &TestHomeserver) -> Result<String> {
    let user = server
        .register_user("compat_sync", "compat_sync_pass")
        .await?;
    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    client.login(&user.localpart, "compat_sync_pass").await?;
    client.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    let _rooms = client.joined_rooms().await;

    Ok("sync_once_with_timeout and joined_rooms completed".to_owned())
}

async fn rooms_behavior(server: &TestHomeserver) -> Result<String> {
    let alice_reg = server
        .register_user("compat_rooms_alice", "compat_rooms_pass")
        .await?;
    let bob_reg = server
        .register_user("compat_rooms_bob", "compat_rooms_pass")
        .await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    alice
        .login(&alice_reg.localpart, "compat_rooms_pass")
        .await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    bob.login(&bob_reg.localpart, "compat_rooms_pass").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Compatibility Rooms".to_owned()),
            invite: vec![bob_reg.user_id.clone()],
            ..Default::default()
        })
        .await?;

    bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.join_room(&room_id).await?;
    alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    let members = alice.room_members(&room_id).await?;

    if !members
        .iter()
        .any(|member| member.contains(bob_reg.localpart.as_str()))
    {
        bail!("joined room members did not include compat_rooms_bob: {members:?}");
    }

    Ok("created room, invited user, joined, and read members".to_owned())
}

async fn messaging_behavior(server: &TestHomeserver) -> Result<String> {
    let alice_reg = server
        .register_user("compat_msg_alice", "compat_msg_pass")
        .await?;
    let bob_reg = server
        .register_user("compat_msg_bob", "compat_msg_pass")
        .await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    alice.login(&alice_reg.localpart, "compat_msg_pass").await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    bob.login(&bob_reg.localpart, "compat_msg_pass").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Compatibility Messaging".to_owned()),
            invite: vec![bob_reg.user_id.clone()],
            ..Default::default()
        })
        .await?;

    alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.join_room(&room_id).await?;
    alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    alice
        .send_text(&room_id, "compatibility report message")
        .await?;
    bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;

    let messages = bob.get_messages(&room_id, None, 20).await?;
    if !messages
        .messages
        .iter()
        .any(|message| message.body == "compatibility report message")
    {
        bail!("Bob did not receive compatibility report message");
    }

    Ok("sent text message and verified receipt through pagination".to_owned())
}

async fn media_behavior(server: &TestHomeserver) -> Result<String> {
    let user = server
        .register_user("compat_media", "compat_media_pass")
        .await?;
    let store = tempfile::tempdir()?;
    let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    client.login(&user.localpart, "compat_media_pass").await?;
    let capabilities = client.server_capabilities().await?;

    let room_id = client
        .create_room(CreateRoomOptions {
            name: Some("Compatibility Media".to_owned()),
            ..Default::default()
        })
        .await?;
    client.sync_once_with_timeout(SYNC_TIMEOUT).await?;

    let uploaded = b"compatibility media content".to_vec();
    client
        .upload_media(
            &room_id,
            "compatibility.txt",
            "text/plain",
            uploaded.clone(),
        )
        .await?;
    client.sync_once_with_timeout(SYNC_TIMEOUT).await?;

    let messages = client.get_messages(&room_id, None, 10).await?;
    let mxc = messages
        .messages
        .iter()
        .find(|message| message.body.contains("compatibility.txt"))
        .and_then(|message| message.mxc_uri.as_deref())
        .context("uploaded media message did not expose an mxc URI")?;
    let downloaded = client.download_media(mxc).await?;

    if downloaded != uploaded {
        bail!("downloaded media did not match uploaded bytes");
    }

    Ok(format!(
        "uploaded and downloaded media bytes; supports_authenticated_media={}",
        capabilities.supports_authenticated_media
    ))
}

async fn e2ee_behavior(server: &TestHomeserver) -> Result<String> {
    let alice_reg = server
        .register_user("compat_e2ee_alice", "compat_e2ee_pass")
        .await?;
    let bob_reg = server
        .register_user("compat_e2ee_bob", "compat_e2ee_pass")
        .await?;

    let alice_store = tempfile::tempdir()?;
    let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
    alice
        .login(&alice_reg.localpart, "compat_e2ee_pass")
        .await?;

    let bob_store = tempfile::tempdir()?;
    let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
    bob.login(&bob_reg.localpart, "compat_e2ee_pass").await?;

    let room_id = alice
        .create_room(CreateRoomOptions {
            name: Some("Compatibility E2EE".to_owned()),
            invite: vec![bob_reg.user_id.clone()],
            ..Default::default()
        })
        .await?;

    alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.join_room(&room_id).await?;
    alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
    alice.enable_encryption(&room_id).await?;

    for _ in 0..3 {
        alice.sync_once_with_timeout(SYNC_TIMEOUT).await?;
        bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    alice.send_text(&room_id, "compatibility encrypted").await?;
    for _ in 0..3 {
        bob.sync_once_with_timeout(SYNC_TIMEOUT).await?;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    let messages = bob.get_messages(&room_id, None, 10).await?;
    if !messages
        .messages
        .iter()
        .any(|message| message.body == "compatibility encrypted")
    {
        bail!("Bob did not read decrypted compatibility message");
    }

    Ok("encrypted room message decrypted through pagination".to_owned())
}

async fn ffi_smoke_behavior(server: &TestHomeserver) -> Result<String> {
    let user = server
        .register_user("compat_ffi", "compat_ffi_pass")
        .await?;
    let localpart = user.localpart;
    let base_url = server.base_url().to_owned();
    let store = tempfile::tempdir()?;
    let store_path = store
        .path()
        .to_str()
        .context("store path was not UTF-8")?
        .to_owned();

    tokio::task::spawn_blocking(move || unsafe {
        let url = cstr(&base_url);
        let path = cstr(&store_path);

        let new_result = manymatrix_ffi::manymatrix_new(url.as_ptr(), path.as_ptr());
        assert_ffi_ok(&new_result)?;
        let handle = new_result.data as *mut manymatrix_ffi::ManyMatrixClient;

        let username = cstr(&localpart);
        let password = cstr("compat_ffi_pass");
        let login_result =
            manymatrix_ffi::manymatrix_login(handle, username.as_ptr(), password.as_ptr());
        let session = read_ffi_string(&login_result)?;
        if !session.contains(localpart.as_str()) {
            bail!("FFI login session did not contain compat_ffi");
        }

        let sync_result = manymatrix_ffi::manymatrix_sync_once(handle);
        assert_ffi_ok(&sync_result)?;

        let whoami_result = manymatrix_ffi::manymatrix_whoami(handle);
        let user_id = read_ffi_string(&whoami_result)?;
        if !user_id.starts_with(&format!("@{localpart}:")) {
            bail!("FFI whoami returned unexpected user ID: {user_id}");
        }

        let logout_result = manymatrix_ffi::manymatrix_logout(handle);
        assert_ffi_ok(&logout_result)?;
        manymatrix_ffi::manymatrix_free(handle);

        Ok::<_, anyhow::Error>("created, logged in, synced, whoami, and logged out".to_owned())
    })
    .await?
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test strings do not contain NUL bytes")
}

unsafe fn assert_ffi_ok(result: &manymatrix_ffi::FfiResult) -> Result<()> {
    if result.ok {
        Ok(())
    } else {
        bail!("FFI call failed: {}", ffi_error(result))
    }
}

unsafe fn read_ffi_string(result: &manymatrix_ffi::FfiResult) -> Result<String> {
    assert_ffi_ok(result)?;
    if result.data.is_null() {
        bail!("expected FFI string data, got null");
    }

    Ok(CStr::from_ptr(result.data as *const c_char)
        .to_str()
        .context("FFI string was not UTF-8")?
        .to_owned())
}

unsafe fn ffi_error(result: &manymatrix_ffi::FfiResult) -> String {
    if result.error_msg.is_null() {
        "(no error)".to_owned()
    } else {
        CStr::from_ptr(result.error_msg)
            .to_str()
            .unwrap_or("(invalid UTF-8 error)")
            .to_owned()
    }
}

fn assert_report_invariants(report: &CompatibilityReport) {
    assert_eq!(report.schema_version, 1);
    assert!(!report.servers.is_empty(), "report should include servers");

    for server in &report.servers {
        assert_versions_probe_shape(server);
        assert_behavior_shape(server);

        if server.metadata.kind == "synapse" {
            assert_eq!(
                server.metadata.source.label,
                "ghcr.io/matrix-org/synapse-service:v1.117.0"
            );
        }
    }
}

fn assert_versions_probe_shape(server: &ServerCompatibilityReport) {
    assert!(
        server.versions.http_status.is_some() || server.versions.error.is_some(),
        "server {} must include successful versions probe or structured probe error",
        server.metadata.kind
    );
}

fn assert_behavior_shape(server: &ServerCompatibilityReport) {
    for behavior in REQUIRED_BEHAVIORS {
        let matches: Vec<_> = server
            .behaviors
            .iter()
            .filter(|result| result.behavior == behavior)
            .collect();
        assert_eq!(
            matches.len(),
            1,
            "server {} should contain behavior {behavior} exactly once",
            server.metadata.kind
        );

        if matches[0].status == BehaviorStatus::Skip {
            assert!(
                matches[0]
                    .reason
                    .as_deref()
                    .is_some_and(|reason| !reason.trim().is_empty()),
                "skip reason must be non-empty for server {} behavior {behavior}",
                server.metadata.kind
            );
        }
    }
}

fn path_has_target_compat(path: &Path) -> bool {
    let mut saw_target = false;
    for component in path.components() {
        let component = component.as_os_str();
        if component == "target" {
            saw_target = true;
        } else if saw_target && component == "compat" {
            return true;
        }
    }
    false
}
