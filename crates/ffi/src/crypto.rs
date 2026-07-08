use std::ffi::c_char;

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::types::FfiResult;
use crate::{str_from_ptr, RUNTIME};

/// Enable end-to-end encryption on a room.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_enable_encryption(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.enable_encryption(room_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Start SAS device verification with a specific user's device.
///
/// Returns the flow ID string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_start_verification(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    device_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let device_id = str_from_ptr(device_id);
    match RUNTIME.block_on(client.start_verification(user_id, device_id)) {
        Ok(flow_id) => FfiResult::success_string(&flow_id),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Accept an incoming SAS verification request.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_accept_verification(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.accept_verification(user_id, flow_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Transition an accepted verification request into a SAS flow.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_start_sas(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.start_sas(user_id, flow_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Accept an in-progress SAS verification so short auth strings can be shown.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_accept_sas(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.accept_sas(user_id, flow_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the SAS emoji set for visual comparison during verification.
///
/// Returns a JSON-serialized `SasEmojis` in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_get_sas_emojis(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.get_sas_emojis(user_id, flow_id)) {
        Ok(emojis) => match serde_json::to_string(&emojis) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error_from(&e),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Confirm the SAS verification after comparing emojis.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_confirm_sas(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.confirm_sas(user_id, flow_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Cancel an ongoing verification flow.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_cancel_verification(
    handle: *mut ManyMatrixClient,
    user_id: *const c_char,
    flow_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let user_id = str_from_ptr(user_id);
    let flow_id = str_from_ptr(flow_id);
    match RUNTIME.block_on(client.cancel_verification(user_id, flow_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Bootstrap cross-signing keys for this account.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_bootstrap_cross_signing(
    handle: *mut ManyMatrixClient,
) -> FfiResult {
    let client = client_from_handle(handle);
    match RUNTIME.block_on(client.bootstrap_cross_signing()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Create a new server-side key backup.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_setup_key_backup(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = client_from_handle(handle);
    match RUNTIME.block_on(client.setup_key_backup()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Restore room keys from a server-side backup using the recovery key.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_restore_key_backup(
    handle: *mut ManyMatrixClient,
    recovery_key: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let recovery_key = str_from_ptr(recovery_key);
    match RUNTIME.block_on(client.restore_key_backup(recovery_key)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Enable secret storage and key backup recovery.
///
/// Returns the recovery key string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_enable_recovery(handle: *mut ManyMatrixClient) -> FfiResult {
    let client = client_from_handle(handle);
    match RUNTIME.block_on(client.enable_recovery()) {
        Ok(recovery_key) => FfiResult::success_string(&recovery_key),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Block until all locally-created room keys have finished uploading to the
/// server-side backup.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_wait_for_backup_upload(
    handle: *mut ManyMatrixClient,
) -> FfiResult {
    let client = client_from_handle(handle);
    match RUNTIME.block_on(client.wait_for_backup_upload()) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}
