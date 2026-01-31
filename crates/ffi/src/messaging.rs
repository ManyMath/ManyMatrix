use std::ffi::c_char;

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::types::FfiResult;
use crate::{optional_str_from_ptr, str_from_ptr, RUNTIME};

/// Send a plain-text message to a room. Returns the event ID string.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_text(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let body = str_from_ptr(body);
    match RUNTIME.block_on(client.send_text(room_id, body)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send a formatted HTML message to a room. Returns the event ID string.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_html(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    body: *const c_char,
    html: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let body = str_from_ptr(body);
    let html = str_from_ptr(html);
    match RUNTIME.block_on(client.send_html(room_id, body, html)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send a notice message to a room. Returns the event ID string.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_notice(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let body = str_from_ptr(body);
    match RUNTIME.block_on(client.send_notice(room_id, body)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send an emote message to a room (e.g. /me action). Returns the event ID string.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_emote(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let body = str_from_ptr(body);
    match RUNTIME.block_on(client.send_emote(room_id, body)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Edit a previously sent message. Void return on success.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_edit_message(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_id: *const c_char,
    new_body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_id = str_from_ptr(event_id);
    let new_body = str_from_ptr(new_body);
    match RUNTIME.block_on(client.edit_message(room_id, event_id, new_body)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Reply to a message in a room. Returns the event ID of the reply.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_reply_to(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_id: *const c_char,
    body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_id = str_from_ptr(event_id);
    let body = str_from_ptr(body);
    match RUNTIME.block_on(client.reply_to(room_id, event_id, body)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send an emoji reaction to an event. Returns the event ID of the reaction.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_reaction(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_id: *const c_char,
    key: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_id = str_from_ptr(event_id);
    let key = str_from_ptr(key);
    match RUNTIME.block_on(client.send_reaction(room_id, event_id, key)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Redact (delete) an event from a room. Reason is optional (may be null).
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `reason` may be null.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_redact(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_id: *const c_char,
    reason: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_id = str_from_ptr(event_id);
    let reason = optional_str_from_ptr(reason);
    match RUNTIME.block_on(client.redact(room_id, event_id, reason)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send a threaded reply to a message. Returns the event ID of the reply.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_thread_reply(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    thread_root_id: *const c_char,
    body: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let thread_root_id = str_from_ptr(thread_root_id);
    let body = str_from_ptr(body);
    match RUNTIME.block_on(client.send_thread_reply(room_id, thread_root_id, body)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send a read receipt for the given event in the given room.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_read_receipt(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    event_id: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let event_id = str_from_ptr(event_id);
    match RUNTIME.block_on(client.send_read_receipt(room_id, event_id)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Send a typing indicator to the given room.
///
/// Pass `true` to start typing, `false` to stop.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_send_typing(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    typing: bool,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    match RUNTIME.block_on(client.send_typing(room_id, typing)) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error(&e.to_string()),
    }
}

/// Load messages from a room with backward pagination.
///
/// `from_token` may be null for the first page. `limit` is the number of messages.
/// Returns a JSON-serialized `PaginatedMessages` in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `from_token` may be null.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_get_messages(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    from_token: *const c_char,
    limit: u32,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let from_token = optional_str_from_ptr(from_token);
    match RUNTIME.block_on(client.get_messages(room_id, from_token, limit)) {
        Ok(paginated) => match serde_json::to_string(&paginated) {
            Ok(json) => FfiResult::success_string(&json),
            Err(e) => FfiResult::error(&e.to_string()),
        },
        Err(e) => FfiResult::error(&e.to_string()),
    }
}
