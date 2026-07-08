use std::ffi::c_char;

use manymatrix_core::{CreateRoomOptions, RoomVisibility};
use serde::Deserialize;

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::types::FfiResult;
use crate::{optional_str_from_ptr, str_from_ptr, RUNTIME};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CustomEventPowerLevelsConfig {
    required_power_level: i64,
    #[serde(default)]
    user_power_levels: std::collections::BTreeMap<String, i64>,
}

/// Create a new room with the given name and topic.
///
/// Returns the room ID string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `name` and `topic` may be null.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_create_room(
    handle: *mut ManyMatrixClient,
    name: *const c_char,
    topic: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let options = CreateRoomOptions {
        name: optional_str_from_ptr(name).map(|s| s.to_owned()),
        topic: optional_str_from_ptr(topic).map(|s| s.to_owned()),
        invite: vec![],
        visibility: RoomVisibility::Private,
    };
    match RUNTIME.block_on(client.create_room(options)) {
        Ok(room_id) => FfiResult::success_string(&room_id),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Join a room by ID or alias.
///
/// Returns the room ID string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `room_id_or_alias` must be valid UTF-8.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_join_room(
    handle: *mut ManyMatrixClient,
    room_id_or_alias: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let id = str_from_ptr(room_id_or_alias);
    match RUNTIME.block_on(client.join_room(id)) {
        Ok(room_id) => FfiResult::success_string(&room_id),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Invite a user to a room.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_invite(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    user_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let user_id = str_from_ptr(user_id);
    match RUNTIME.block_on(client.invite(room_id, user_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Configure the power level required to send a custom event type in a room.
///
/// `config_json` must be a JSON object with `requiredPowerLevel` and optional
/// `userPowerLevels` map of Matrix user ID to power level.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_set_custom_event_power_levels(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_type: *const c_char,
    config_json: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_type = str_from_ptr(event_type);
    let config_json = str_from_ptr(config_json);
    let config: CustomEventPowerLevelsConfig = match serde_json::from_str(config_json) {
        Ok(config) => config,
        Err(e) => return FfiResult::serde_error(&format!("invalid config_json: {e}")),
    };
    match RUNTIME.block_on(client.set_custom_event_power_levels(
        room_id,
        event_type,
        config.required_power_level,
        config.user_power_levels.into_iter().collect(),
    )) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Return the room power-level snapshot as a JSON string.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_room_power_levels(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.room_power_levels(room_id)) {
        Ok(snapshot) => match serde_json::to_string(&snapshot) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::serde_error(&format!("invalid power-level snapshot: {e}")),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Leave a room.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_leave_room(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.leave_room(room_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Kick a user from a room with optional reason.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `reason` may be null.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_kick(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    user_id: *const c_char,
    reason: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let user_id = str_from_ptr(user_id);
    let reason = optional_str_from_ptr(reason);
    match RUNTIME.block_on(client.kick(room_id, user_id, reason)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Ban a user from a room with optional reason.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `reason` may be null.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_ban(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    user_id: *const c_char,
    reason: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let user_id = str_from_ptr(user_id);
    let reason = optional_str_from_ptr(reason);
    match RUNTIME.block_on(client.ban(room_id, user_id, reason)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the room's name, or null data if not set.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_room_name(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match client.room_name(room_id) {
        Ok(Some(name)) => FfiResult::success_string(&name),
        Ok(None) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the room's topic, or null data if not set.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_room_topic(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match client.room_topic(room_id) {
        Ok(Some(topic)) => FfiResult::success_string(&topic),
        Ok(None) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the room's avatar URL (mxc:// URI), or null data if not set.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_room_avatar_url(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match client.room_avatar_url(room_id) {
        Ok(Some(url)) => FfiResult::success_string(&url),
        Ok(None) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Get the list of joined member user IDs for a room as a JSON array.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_room_members(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.room_members(room_id)) {
        Ok(members) => match serde_json::to_string(&members) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error_from(&e),
        },
        Err(e) => FfiResult::error_from(&e),
    }
}
