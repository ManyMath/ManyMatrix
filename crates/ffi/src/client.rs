use std::ffi::{c_char, c_void, CString};
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread::JoinHandle;
use std::time::Duration;

use manymatrix_core::{ClientOptions, ManyMatrixClient as CoreClient};

use crate::types::{FfiErrorSource, FfiResult, SessionUpdateCallback, SyncStatusCallback};
use crate::{ffi_try, optional_str_from_ptr, str_from_ptr, RUNTIME};

/// Opaque FFI handle for the core Matrix client.
pub struct ManyMatrixClient {
    client: CoreClient,
    sync_thread: Mutex<Option<JoinHandle<()>>>,
    sync_cancel: Arc<AtomicBool>,
}

/// Borrow the core client behind an FFI handle.
///
/// A null handle becomes a `StorageError` result instead of a crash.
///
/// # Safety
/// If non-null, `handle` must be a live pointer returned by `manymatrix_new`.
pub(crate) unsafe fn client_from_handle<'a>(
    handle: *mut ManyMatrixClient,
) -> Result<&'a CoreClient, FfiResult> {
    ffi_client_from_handle(handle).map(|ffi_client| &ffi_client.client)
}

unsafe fn ffi_client_from_handle<'a>(
    handle: *mut ManyMatrixClient,
) -> Result<&'a ManyMatrixClient, FfiResult> {
    handle
        .as_ref()
        .ok_or_else(|| FfiResult::storage_error("client handle is null"))
}

impl ManyMatrixClient {
    fn new(client: CoreClient) -> Self {
        Self {
            client,
            sync_thread: Mutex::new(None),
            sync_cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    fn store_sync_thread(&self, thread: JoinHandle<()>) {
        *self.sync_thread.lock().expect("sync thread mutex poisoned") = Some(thread);
    }

    fn stop_sync_thread(&self) {
        self.sync_cancel.store(true, Ordering::SeqCst);
        let thread = self
            .sync_thread
            .lock()
            .expect("sync thread mutex poisoned")
            .take();
        if let Some(thread) = thread {
            let _ = thread.join();
        }
        self.sync_cancel.store(false, Ordering::SeqCst);
    }
}

fn sync_status_json(state: &str, ok: bool, error: Option<String>) -> serde_json::Value {
    let mut status = serde_json::json!({
        "state": state,
        "ok": ok,
    });
    if let Some(error) = error {
        status["error"] = serde_json::Value::String(error);
    }
    status
}

fn failed_sync_status_json(error: &manymatrix_core::Error) -> serde_json::Value {
    let mut status = sync_status_json("exited", false, Some(error.to_string()));
    status["errorKind"] = serde_json::Value::String(error.ffi_kind().to_string());
    status["errorDetails"] = error.ffi_details();
    status
}

fn send_sync_status(callback: SyncStatusCallback, status: serde_json::Value) {
    if let Ok(json) = serde_json::to_string(&status) {
        if let Ok(cstr) = CString::new(json) {
            callback(cstr.into_raw());
        }
    }
}

fn send_session_update(callback: SessionUpdateCallback, session_json: String) {
    if let Ok(cstr) = CString::new(session_json) {
        callback(cstr.into_raw());
    }
}

/// Create a new ManyMatrixClient pointing at the given homeserver URL.
///
/// Returns an opaque handle (pointer) to the client in `FfiResult.data`.
/// The caller must eventually free the handle with `manymatrix_free`.
///
/// # Safety
/// `homeserver_url` and `store_path` must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_new(
    homeserver_url: *const c_char,
    store_path: *const c_char,
) -> FfiResult {
    let url = ffi_try!(str_from_ptr(homeserver_url));
    let path = ffi_try!(str_from_ptr(store_path));
    match RUNTIME.block_on(CoreClient::new(url, Path::new(path))) {
        Ok(client) => {
            let handle = Box::into_raw(Box::new(ManyMatrixClient::new(client)));
            FfiResult::success(handle as *mut c_void)
        }
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Create a new ManyMatrixClient with an optional custom root CA PEM bundle.
///
/// Returns an opaque handle (pointer) to the client in `FfiResult.data`.
/// The caller must eventually free the handle with `manymatrix_free`.
///
/// # Safety
/// `homeserver_url` and `store_path` must be valid, NUL-terminated UTF-8 strings.
/// `custom_ca_certificate_path` may be null; otherwise it must be a valid,
/// NUL-terminated UTF-8 string containing a PEM bundle path.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_new_with_custom_ca(
    homeserver_url: *const c_char,
    store_path: *const c_char,
    custom_ca_certificate_path: *const c_char,
) -> FfiResult {
    let url = ffi_try!(str_from_ptr(homeserver_url));
    let path = ffi_try!(str_from_ptr(store_path));
    let custom_ca_certificate_path = ffi_try!(optional_str_from_ptr(custom_ca_certificate_path))
        .filter(|value| !value.is_empty());
    let mut options = ClientOptions::default();
    if let Some(path) = custom_ca_certificate_path {
        options = options.with_custom_root_certificate_path(path);
    }
    match RUNTIME.block_on(CoreClient::new_with_options(url, Path::new(path), options)) {
        Ok(client) => {
            let handle = Box::into_raw(Box::new(ManyMatrixClient::new(client)));
            FfiResult::success(handle as *mut c_void)
        }
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Login with username and password.
///
/// Returns a JSON-serialized `StoredSession` string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `username` and `password`
/// must be valid, NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_login(
    handle: *mut ManyMatrixClient,
    username: *const c_char,
    password: *const c_char,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let username = ffi_try!(str_from_ptr(username));
    let password = ffi_try!(str_from_ptr(password));
    match RUNTIME.block_on(client.login(username, password)) {
        Ok(session) => match serde_json::to_string(&session) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error_from(&e),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Login with username and password, reusing an existing Matrix device.
///
/// Passing the device ID of a previous session for the same user keeps the
/// crypto store bound to that device instead of registering a new one, which
/// is what a re-authentication after token expiry needs. `device_id` may be
/// null or empty to let the homeserver allocate a fresh device.
///
/// Returns a JSON-serialized `StoredSession` string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `username` and `password`
/// must be valid, NUL-terminated UTF-8 strings; `device_id` must be either
/// null or such a string.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_login_with_device_id(
    handle: *mut ManyMatrixClient,
    username: *const c_char,
    password: *const c_char,
    device_id: *const c_char,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let username = ffi_try!(str_from_ptr(username));
    let password = ffi_try!(str_from_ptr(password));
    let device_id = ffi_try!(optional_str_from_ptr(device_id)).filter(|value| !value.is_empty());
    match RUNTIME.block_on(client.login_with_device_id(username, password, device_id)) {
        Ok(session) => match serde_json::to_string(&session) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error_from(&e),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Restore a previously saved session from JSON.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `session_json` must be a
/// valid, NUL-terminated UTF-8 string containing a JSON-serialized StoredSession.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_restore(
    handle: *mut ManyMatrixClient,
    session_json: *const c_char,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let json = ffi_try!(str_from_ptr(session_json));
    let session: manymatrix_core::StoredSession = match serde_json::from_str(json) {
        Ok(s) => s,
        Err(e) => return FfiResult::error_from(&e),
    };
    match RUNTIME.block_on(client.restore(&session)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the current JSON-serialized StoredSession, including any refreshed
/// access/refresh tokens known to the SDK.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_current_session(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match client.current_session_json() {
        Ok(Some(json)) => FfiResult::success_string(&json),
        Ok(None) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Register a callback for refreshed session JSON updates.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
/// `callback` must remain valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_session_update(
    handle: *mut ManyMatrixClient,
    callback: SessionUpdateCallback,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    client.set_session_update_callback(move |session_json| {
        send_session_update(callback, session_json);
    });
    FfiResult::success_void()
}

/// Perform a single sync round.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_once(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match RUNTIME.block_on(client.sync_once()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Perform a single sync round with an explicit long-poll timeout.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_once_with_timeout(
    handle: *mut ManyMatrixClient,
    timeout_ms: u64,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match RUNTIME.block_on(client.sync_once_with_timeout(Duration::from_millis(timeout_ms))) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Start the sync loop on a background thread.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer for this call.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_forever(handle: *mut ManyMatrixClient) -> FfiResult {
    let ffi_client = ffi_try!(ffi_client_from_handle(handle));
    ffi_client.stop_sync_thread();
    let client = ffi_client.client.clone();
    let cancelled = ffi_client.sync_cancel.clone();
    let thread = std::thread::spawn(move || {
        RUNTIME
            .block_on(client.sync_until_cancelled(cancelled))
            .ok();
    });
    ffi_client.store_sync_thread(thread);
    FfiResult::success_void()
}

/// Start the sync loop on a background thread and report when it exits.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer for this call.
/// `callback` must remain valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_forever_with_status(
    handle: *mut ManyMatrixClient,
    callback: SyncStatusCallback,
) -> FfiResult {
    let ffi_client = ffi_try!(ffi_client_from_handle(handle));
    ffi_client.stop_sync_thread();
    let client = ffi_client.client.clone();
    let cancelled = ffi_client.sync_cancel.clone();
    let thread = std::thread::spawn(move || {
        send_sync_status(callback, sync_status_json("running", true, None));
        let result = RUNTIME.block_on(client.sync_until_cancelled(cancelled));
        let status = match result {
            Ok(()) => sync_status_json("exited", true, None),
            Err(error) => failed_sync_status_json(&error),
        };
        send_sync_status(callback, status);
    });
    ffi_client.store_sync_thread(thread);
    FfiResult::success_void()
}

/// Stop the background sync loop if it is running.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer for this call.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_stop_sync(handle: *mut ManyMatrixClient) -> FfiResult {
    let ffi_client = ffi_try!(ffi_client_from_handle(handle));
    ffi_client.stop_sync_thread();
    FfiResult::success_void()
}

/// Get the list of joined rooms as a JSON array of RoomSummary objects.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_joined_rooms(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let rooms = RUNTIME.block_on(client.joined_rooms());
    match serde_json::to_string(&rooms) {
        Ok(json) => FfiResult::success_string(&json),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the list of invited rooms as a JSON array of RoomInvite objects.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_invited_rooms(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let rooms = RUNTIME.block_on(client.invited_rooms());
    match serde_json::to_string(&rooms) {
        Ok(json) => FfiResult::success_string(&json),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get Matrix server version and capability data as JSON.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_server_capabilities(
    handle: *mut ManyMatrixClient,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match RUNTIME.block_on(client.server_capabilities()) {
        Ok(capabilities) => match serde_json::to_string(&capabilities) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error_from(&e),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Logout: stop the background sync thread, invalidate the server token, and
/// delete local state.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_logout(handle: *mut ManyMatrixClient) -> FfiResult {
    let ffi_client = ffi_try!(ffi_client_from_handle(handle));
    // The sync thread holds its own client clone: left running it would keep
    // long-polling with the revoked token and then report a failed exit.
    ffi_client.stop_sync_thread();
    match RUNTIME.block_on(ffi_client.client.logout()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Free a ManyMatrixClient handle.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer previously returned by
/// `manymatrix_new`, or null (in which case this is a no-op).
/// After calling this, the handle must not be used again.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_free(handle: *mut ManyMatrixClient) {
    if !handle.is_null() {
        let client = Box::from_raw(handle);
        client.stop_sync_thread();
        // Drop inside runtime context so deadpool (SQLite pool) can clean up.
        RUNTIME.block_on(async move { drop(client) });
    }
}

/// Get the current sync token, if any.
///
/// Returns a string in `FfiResult.data` or null data if no token is available.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_token(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match RUNTIME.block_on(client.sync_token_clone()) {
        Some(token) => FfiResult::success_string(&token),
        None => FfiResult::success_void(),
    }
}

/// Get the current logged-in user's Matrix ID (e.g. "@alice:example.com").
///
/// Returns the user ID string in `FfiResult.data`, or null data when no user
/// is logged in (the web bridge answers `null` in the same situation).
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_whoami(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    match client.current_user_id() {
        Some(id) => FfiResult::success_string(&id),
        None => FfiResult::success_void(),
    }
}

/// Check whether a room has encryption enabled.
///
/// Returns "true" or "false" as a string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `room_id` must be a valid,
/// NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_is_room_encrypted(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = ffi_try!(client_from_handle(handle));
    let room_id = ffi_try!(str_from_ptr(room_id));
    match RUNTIME.block_on(client.is_room_encrypted(room_id)) {
        Ok(encrypted) => FfiResult::success_string(if encrypted { "true" } else { "false" }),
        Err(e) => FfiResult::error_from(&e),
    }
}

#[cfg(test)]
mod tests {
    use super::{failed_sync_status_json, manymatrix_new_with_custom_ca, sync_status_json};
    use crate::ffi_free_result;
    use std::ffi::{CStr, CString};

    #[test]
    fn sync_status_json_omits_error_for_running_state() {
        let status = sync_status_json("running", true, None);

        assert_eq!(status["state"], "running");
        assert_eq!(status["ok"], true);
        assert!(status.get("error").is_none());
    }

    #[test]
    fn sync_status_json_includes_error_for_failed_exit() {
        let status = sync_status_json("exited", false, Some("network dropped".to_owned()));

        assert_eq!(status["state"], "exited");
        assert_eq!(status["ok"], false);
        assert_eq!(status["error"], "network dropped");
    }

    #[test]
    fn failed_sync_status_json_includes_structured_error_fields() {
        let error = manymatrix_core::Error::IdParse("bad room id".to_string());
        let status = failed_sync_status_json(&error);

        assert_eq!(status["state"], "exited");
        assert_eq!(status["ok"], false);
        assert_eq!(status["error"], "ID parse error: bad room id");
        assert_eq!(status["errorKind"], "SerdeError");
        assert!(status["errorDetails"].as_object().unwrap().is_empty());
    }

    #[test]
    fn custom_ca_constructor_reports_certificate_path_errors_before_network() {
        let url = CString::new("http://127.0.0.1:9").unwrap();
        let store_path = std::env::temp_dir()
            .join(format!("manymatrix-custom-ca-ffi-{}", std::process::id()))
            .to_string_lossy()
            .into_owned();
        let store_path = CString::new(store_path).unwrap();
        let missing_ca = CString::new(
            std::env::temp_dir()
                .join(format!(
                    "manymatrix-missing-ca-ffi-{}.pem",
                    std::process::id()
                ))
                .to_string_lossy()
                .into_owned(),
        )
        .unwrap();

        let result = unsafe {
            manymatrix_new_with_custom_ca(url.as_ptr(), store_path.as_ptr(), missing_ca.as_ptr())
        };
        assert!(!result.ok);
        let error = unsafe {
            CStr::from_ptr(result.error_msg)
                .to_string_lossy()
                .into_owned()
        };
        assert!(error.contains("could not read custom root certificate"));
        ffi_free_result(result);
    }
}
