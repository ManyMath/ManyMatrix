use std::ffi::{c_char, c_void};
use std::path::Path;

use manymatrix_core::ManyMatrixClient;

use crate::types::FfiResult;
use crate::{str_from_ptr, RUNTIME};

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
    let url = str_from_ptr(homeserver_url);
    let path = str_from_ptr(store_path);
    match RUNTIME.block_on(ManyMatrixClient::new(url, Path::new(path))) {
        Ok(client) => {
            let handle = Box::into_raw(Box::new(client));
            FfiResult::success(handle as *mut c_void)
        }
        Err(e) => FfiResult::error(&e.to_string()),
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
    let client = &*handle;
    let username = str_from_ptr(username);
    let password = str_from_ptr(password);
    match RUNTIME.block_on(client.login(username, password)) {
        Ok(session) => match serde_json::to_string(&session) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error(&e.to_string()),
        },
        Err(e) => FfiResult::error(&e.to_string()),
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
    let client = &*handle;
    let json = str_from_ptr(session_json);
    let session: manymatrix_core::StoredSession = match serde_json::from_str(json) {
        Ok(s) => s,
        Err(e) => return FfiResult::error(&e.to_string()),
    };
    match RUNTIME.block_on(client.restore(&session)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Perform a single sync round.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_once(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = &*handle;
    match RUNTIME.block_on(client.sync_once()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Start the sync loop on a background thread.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer that outlives the sync loop.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_sync_forever(handle: *mut ManyMatrixClient) -> FfiResult {
    // We need a 'static reference for the spawned thread. The caller guarantees
    // the handle remains valid (they must call manymatrix_free only after stopping sync).
    let client_ref: &'static ManyMatrixClient = &*(handle as *const ManyMatrixClient);
    std::thread::spawn(move || {
        RUNTIME.block_on(client_ref.sync_forever()).ok();
    });
    FfiResult::success_void()
}

/// Get the list of joined rooms as a JSON array of RoomSummary objects.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_joined_rooms(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = &*handle;
    let rooms = RUNTIME.block_on(client.joined_rooms());
    match serde_json::to_string(&rooms) {
        Ok(json) => FfiResult::success_string(&json),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Logout: invalidate server token and delete local state.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_logout(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = &*handle;
    match RUNTIME.block_on(client.logout()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
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
    let client = &*handle;
    match RUNTIME.block_on(client.sync_token_clone()) {
        Some(token) => FfiResult::success_string(&token),
        None => FfiResult::success_void(),
    }
}

/// Get the current logged-in user's Matrix ID (e.g. "@alice:example.com").
///
/// Returns the user ID string in `FfiResult.data`, or an error if not logged in.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_whoami(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = &*handle;
    match client.current_user_id() {
        Some(id) => FfiResult::success_string(&id),
        None => FfiResult::error("not logged in"),
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
    let client = &*handle;
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.is_room_encrypted(room_id)) {
        Ok(encrypted) => FfiResult::success_string(if encrypted { "true" } else { "false" }),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}
