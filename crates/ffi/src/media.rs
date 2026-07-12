use std::ffi::{c_char, c_void};

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::types::{FfiBuffer, FfiResult};
use crate::{str_from_ptr, RUNTIME};

/// Upload a file as an attachment to a room.
///
/// Returns the event ID string in `FfiResult.data`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `data` must point to
/// `data_len` valid bytes.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_upload_media(
    handle: *mut ManyMatrixClient,
    room_id: *const c_char,
    filename: *const c_char,
    mime_type: *const c_char,
    data: *const u8,
    data_len: usize,
) -> FfiResult {
    let client = client_from_handle(handle);
    let room_id = str_from_ptr(room_id);
    let filename = str_from_ptr(filename);
    let mime_type = str_from_ptr(mime_type);
    let bytes = std::slice::from_raw_parts(data, data_len).to_vec();
    match RUNTIME.block_on(client.upload_media(room_id, filename, mime_type, bytes)) {
        Ok(event_id) => FfiResult::success_string(&event_id),
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Download media content by its mxc:// URI.
///
/// Returns an `FfiBuffer` pointer in `FfiResult.data`. Free with `ffi_free_buffer`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_download_media(
    handle: *mut ManyMatrixClient,
    mxc_uri: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let mxc_uri = str_from_ptr(mxc_uri);
    match RUNTIME.block_on(client.download_media(mxc_uri)) {
        Ok(data) => {
            let mut boxed = data.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            let len = boxed.len();
            std::mem::forget(boxed);
            let buf = Box::new(FfiBuffer { data: ptr, len });
            FfiResult::success(Box::into_raw(buf) as *mut c_void)
        }
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Download media from a serialized plain or encrypted Matrix `MediaSource`.
///
/// Returns an `FfiBuffer` pointer in `FfiResult.data`. Free with `ffi_free_buffer`.
///
/// # Safety
/// `handle` must be valid and `media_source_json` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_download_media_source(
    handle: *mut ManyMatrixClient,
    media_source_json: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let media_source_json = str_from_ptr(media_source_json);
    let media_source: serde_json::Value = match serde_json::from_str(media_source_json) {
        Ok(value) => value,
        Err(error) => {
            return FfiResult::error(&format!("invalid media source JSON: {error}"));
        }
    };
    match RUNTIME.block_on(client.download_media_source(&media_source)) {
        Ok(data) => {
            let mut boxed = data.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            let len = boxed.len();
            std::mem::forget(boxed);
            let buf = Box::new(FfiBuffer { data: ptr, len });
            FfiResult::success(Box::into_raw(buf) as *mut c_void)
        }
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Fetch a thumbnail of media content by its mxc:// URI.
///
/// Returns an `FfiBuffer` pointer in `FfiResult.data`. Free with `ffi_free_buffer`.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_get_thumbnail(
    handle: *mut ManyMatrixClient,
    mxc_uri: *const c_char,
    width: u32,
    height: u32,
) -> FfiResult {
    let client = client_from_handle(handle);
    let mxc_uri = str_from_ptr(mxc_uri);
    match RUNTIME.block_on(client.get_thumbnail(mxc_uri, width, height)) {
        Ok(data) => {
            let mut boxed = data.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            let len = boxed.len();
            std::mem::forget(boxed);
            let buf = Box::new(FfiBuffer { data: ptr, len });
            FfiResult::success(Box::into_raw(buf) as *mut c_void)
        }
        Err(e) => FfiResult::error_from(&e),
    }
}

/// Register a pusher with the homeserver for push notifications.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. All string parameters must be
/// valid, NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_register_pusher(
    handle: *mut ManyMatrixClient,
    app_id: *const c_char,
    push_key: *const c_char,
    app_display_name: *const c_char,
    device_display_name: *const c_char,
    push_url: *const c_char,
    lang: *const c_char,
) -> FfiResult {
    let client = client_from_handle(handle);
    let app_id = str_from_ptr(app_id);
    let push_key = str_from_ptr(push_key);
    let app_display_name = str_from_ptr(app_display_name);
    let device_display_name = str_from_ptr(device_display_name);
    let push_url = str_from_ptr(push_url);
    let lang = str_from_ptr(lang);
    match RUNTIME.block_on(client.register_pusher(
        app_id,
        push_key,
        app_display_name,
        device_display_name,
        push_url,
        lang,
    )) {
        Ok(()) => FfiResult::success_void(),
        Err(e) => FfiResult::error_from(&e),
    }
}
