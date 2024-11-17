#![cfg(feature = "docker-tests")]
use std::ffi::{c_char, CStr, CString};

use anyhow::Result;
use test_harness::{ServerKind, TestHomeserver};
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

unsafe fn read_string(r: &manymatrix_ffi::FfiResult) -> String {
    assert!(r.ok, "FFI failed: {}", ffi_err(r));
    assert!(!r.data.is_null(), "expected string, got null");
    CStr::from_ptr(r.data as *const c_char)
        .to_str()
        .unwrap()
        .to_owned()
}

unsafe fn ffi_err(r: &manymatrix_ffi::FfiResult) -> String {
    if r.error_msg.is_null() {
        "(no error)".into()
    } else {
        CStr::from_ptr(r.error_msg).to_str().unwrap().to_owned()
    }
}

unsafe fn assert_ok(r: &manymatrix_ffi::FfiResult) {
    assert!(r.ok, "FFI failed: {}", ffi_err(r));
}

/// Run FFI calls on a dedicated thread (no tokio runtime in scope),
/// mimicking how Dart's worker isolate calls the C API.
fn on_ffi_thread<F, R>(f: F) -> R
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    std::thread::spawn(f).join().unwrap()
}

/// Full FFI lifecycle against a real Synapse:
/// create client → login → sync ��� create room → send → rooms list → room name → logout → free
#[tokio::test]
async fn ffi_login_sync_send_logout() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    eprintln!("Synapse ready at {}", server.base_url());
    let _alice = server.register_user("alice_ffi", "password1").await?;
    let store = tempfile::tempdir()?;
    let base_url = server.base_url().to_owned();
    let store_path = store.path().to_str().unwrap().to_owned();

    on_ffi_thread(move || unsafe {
        let url = cstr(&base_url);
        let path = cstr(&store_path);

        let r = manymatrix_ffi::manymatrix_new(url.as_ptr(), path.as_ptr());
        assert_ok(&r);
        let h = r.data as *mut manymatrix_core::ManyMatrixClient;

        let u = cstr("alice_ffi");
        let p = cstr("password1");
        let r = manymatrix_ffi::manymatrix_login(h, u.as_ptr(), p.as_ptr());
        let session = read_string(&r);
        assert!(session.contains("alice_ffi"));
        eprintln!("Logged in via FFI");

        let r = manymatrix_ffi::manymatrix_sync_once(h);
        assert_ok(&r);

        let name = cstr("FFI Test Room");
        let r = manymatrix_ffi::manymatrix_create_room(h, name.as_ptr(), std::ptr::null());
        let room_id = read_string(&r);
        assert!(room_id.starts_with('!'));
        eprintln!("Created room: {room_id}");

        let r = manymatrix_ffi::manymatrix_sync_once(h);
        assert_ok(&r);

        let rid = cstr(&room_id);
        let body = cstr("hello from FFI!");
        let r = manymatrix_ffi::manymatrix_send_text(h, rid.as_ptr(), body.as_ptr());
        let event_id = read_string(&r);
        assert!(event_id.starts_with('$'));
        eprintln!("Sent message: {event_id}");

        let r = manymatrix_ffi::manymatrix_joined_rooms(h);
        let rooms = read_string(&r);
        assert!(rooms.contains(&room_id));

        let r = manymatrix_ffi::manymatrix_room_name(h, rid.as_ptr());
        let rname = read_string(&r);
        assert_eq!(rname, "FFI Test Room");

        let r = manymatrix_ffi::manymatrix_room_members(h, rid.as_ptr());
        let members = read_string(&r);
        assert!(members.contains("alice_ffi"));

        let r = manymatrix_ffi::manymatrix_logout(h);
        assert_ok(&r);

        manymatrix_ffi::manymatrix_free(h);
        eprintln!("FFI lifecycle complete");
    });

    Ok(())
}

/// Two users communicate entirely through FFI:
/// Alice creates room → invites Bob → Bob joins → Alice sends → Bob reads via pagination
#[tokio::test]
async fn ffi_two_user_messaging() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice = server.register_user("alice_ffi2", "pass1").await?;
    let _bob = server.register_user("bob_ffi2", "pass2").await?;
    let base_url = server.base_url().to_owned();

    let alice_store = tempfile::tempdir()?;
    let bob_store = tempfile::tempdir()?;
    let alice_path = alice_store.path().to_str().unwrap().to_owned();
    let bob_path = bob_store.path().to_str().unwrap().to_owned();

    on_ffi_thread(move || unsafe {
        let url = cstr(&base_url);

        // Alice
        let ap = cstr(&alice_path);
        let r = manymatrix_ffi::manymatrix_new(url.as_ptr(), ap.as_ptr());
        assert_ok(&r);
        let alice = r.data as *mut manymatrix_core::ManyMatrixClient;
        let r = manymatrix_ffi::manymatrix_login(
            alice,
            cstr("alice_ffi2").as_ptr(),
            cstr("pass1").as_ptr(),
        );
        assert!(r.ok);

        // Bob
        let bp = cstr(&bob_path);
        let r = manymatrix_ffi::manymatrix_new(url.as_ptr(), bp.as_ptr());
        assert_ok(&r);
        let bob = r.data as *mut manymatrix_core::ManyMatrixClient;
        let r = manymatrix_ffi::manymatrix_login(
            bob,
            cstr("bob_ffi2").as_ptr(),
            cstr("pass2").as_ptr(),
        );
        assert!(r.ok);

        // Alice creates room, syncs, invites Bob
        let r = manymatrix_ffi::manymatrix_create_room(
            alice,
            cstr("FFI Chat").as_ptr(),
            std::ptr::null(),
        );
        let room_id = read_string(&r);

        let r = manymatrix_ffi::manymatrix_sync_once(alice);
        assert_ok(&r);
        let rid = cstr(&room_id);
        let r = manymatrix_ffi::manymatrix_invite(
            alice,
            rid.as_ptr(),
            cstr("@bob_ffi2:localhost").as_ptr(),
        );
        assert_ok(&r);

        // Bob syncs, joins
        let r = manymatrix_ffi::manymatrix_sync_once(bob);
        assert_ok(&r);
        let r = manymatrix_ffi::manymatrix_join_room(bob, rid.as_ptr());
        assert_ok(&r);

        // Alice syncs, sends text + HTML + reaction
        let r = manymatrix_ffi::manymatrix_sync_once(alice);
        assert_ok(&r);

        let r = manymatrix_ffi::manymatrix_send_text(
            alice,
            rid.as_ptr(),
            cstr("hello bob, from FFI!").as_ptr(),
        );
        let ev_id = read_string(&r);
        assert!(ev_id.starts_with('$'));

        let r = manymatrix_ffi::manymatrix_send_html(
            alice,
            rid.as_ptr(),
            cstr("**bold**").as_ptr(),
            cstr("<b>bold</b>").as_ptr(),
        );
        assert!(r.ok);

        let r = manymatrix_ffi::manymatrix_send_reaction(
            alice,
            rid.as_ptr(),
            cstr(&ev_id).as_ptr(),
            cstr("\u{1F44D}").as_ptr(),
        );
        assert!(r.ok);

        // Bob syncs, checks members, reads messages
        let r = manymatrix_ffi::manymatrix_sync_once(bob);
        assert_ok(&r);

        let r = manymatrix_ffi::manymatrix_room_members(bob, rid.as_ptr());
        let members = read_string(&r);
        assert!(members.contains("alice_ffi2"));
        assert!(members.contains("bob_ffi2"));

        let r = manymatrix_ffi::manymatrix_get_messages(bob, rid.as_ptr(), std::ptr::null(), 10);
        let paginated = read_string(&r);
        assert!(paginated.contains("hello bob, from FFI!"));
        eprintln!("Bob received via FFI pagination: {paginated}");

        manymatrix_ffi::manymatrix_free(alice);
        manymatrix_ffi::manymatrix_free(bob);
    });

    Ok(())
}

/// FFI whoami returns the logged-in user's Matrix ID.
#[tokio::test]
async fn ffi_whoami() -> Result<()> {
    init_tracing();

    let server = TestHomeserver::start(ServerKind::Synapse).await?;
    let _alice = server
        .register_user("alice_ffi_whoami", "password1")
        .await?;
    let store = tempfile::tempdir()?;
    let base_url = server.base_url().to_owned();
    let store_path = store.path().to_str().unwrap().to_owned();

    on_ffi_thread(move || unsafe {
        let url = cstr(&base_url);
        let path = cstr(&store_path);

        // Create client
        let r = manymatrix_ffi::manymatrix_new(url.as_ptr(), path.as_ptr());
        assert_ok(&r);
        let handle = r.data as *mut manymatrix_core::ManyMatrixClient;

        // Login
        let user = cstr("alice_ffi_whoami");
        let pass = cstr("password1");
        let r = manymatrix_ffi::manymatrix_login(handle, user.as_ptr(), pass.as_ptr());
        assert_ok(&r);

        // Call whoami
        let r = manymatrix_ffi::manymatrix_whoami(handle);
        let user_id = read_string(&r);
        assert!(
            user_id.starts_with("@alice_ffi_whoami:"),
            "whoami should return @alice_ffi_whoami:... but got: {}",
            user_id
        );
        eprintln!("FFI whoami returned: {}", user_id);

        // Cleanup
        manymatrix_ffi::manymatrix_free(handle);
    });

    Ok(())
}
