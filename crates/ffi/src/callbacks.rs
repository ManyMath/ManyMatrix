use std::ffi::{c_char, CString};

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::str_from_ptr;
use crate::types::{CustomEventCallback, MessageCallback, ReactionCallback, ReceiptCallback};

/// Register a callback for incoming messages (JSON `MessageEvent`).
///
/// The pointer passed to `callback` is heap-allocated and owned by the callee:
/// the caller must free it with [`crate::ffi_free_string`] once done reading it.
/// `NativeCallable.listener` on the Dart side posts the call to another isolate's
/// event loop and returns before that isolate has read the pointee, so a pointer
/// into a temporary freed when this closure returns is not safe here.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_message(
    handle: *mut ManyMatrixClient,
    callback: MessageCallback,
) {
    // These registrars return nothing, so a null handle is ignored.
    let Ok(client) = client_from_handle(handle) else {
        return;
    };
    client.on_message(move |msg| {
        if let Ok(json) = serde_json::to_string(&msg) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.into_raw());
            }
        }
    });
}

/// Register a callback for incoming reactions (JSON `ReactionEvent`).
///
/// The pointer passed to `callback` is heap-allocated and owned by the callee:
/// the caller must free it with [`crate::ffi_free_string`] once done reading it.
/// See [`manymatrix_on_message`] for why a temporary pointer is not safe here.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_reaction(
    handle: *mut ManyMatrixClient,
    callback: ReactionCallback,
) {
    let Ok(client) = client_from_handle(handle) else {
        return;
    };
    client.on_reaction(move |reaction| {
        if let Ok(json) = serde_json::to_string(&reaction) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.into_raw());
            }
        }
    });
}

/// Register a callback for read receipts (JSON `ReceiptEvent`).
///
/// The pointer passed to `callback` is heap-allocated and owned by the callee:
/// the caller must free it with [`crate::ffi_free_string`] once done reading it.
/// See [`manymatrix_on_message`] for why a temporary pointer is not safe here.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_receipt(
    handle: *mut ManyMatrixClient,
    callback: ReceiptCallback,
) {
    let Ok(client) = client_from_handle(handle) else {
        return;
    };
    client.on_receipt(move |receipt| {
        if let Ok(json) = serde_json::to_string(&receipt) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.into_raw());
            }
        }
    });
}

/// Register a callback for incoming custom message-like events (JSON `CustomEvent`) whose
/// `event_type` matches `event_type` exactly.
///
/// The pointer passed to `callback` is heap-allocated and owned by the callee:
/// the caller must free it with [`crate::ffi_free_string`] once done reading it.
/// See [`manymatrix_on_message`] for why a temporary pointer is not safe here.
///
/// A null handle, or an `event_type` that is null or not UTF-8, registers nothing.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `event_type` must be a valid C string.
/// `callback` must remain valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_custom_event(
    handle: *mut ManyMatrixClient,
    event_type: *const c_char,
    callback: CustomEventCallback,
) {
    let Ok(client) = client_from_handle(handle) else {
        return;
    };
    let Ok(event_type) = str_from_ptr(event_type) else {
        return;
    };
    client.on_custom_event(event_type, move |event| {
        if let Ok(json) = serde_json::to_string(&event) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.into_raw());
            }
        }
    });
}
