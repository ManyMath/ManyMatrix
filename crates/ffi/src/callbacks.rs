use std::ffi::CString;

use manymatrix_core::ManyMatrixClient;

use crate::types::{MessageCallback, ReactionCallback, ReceiptCallback};

/// Register a callback for incoming messages (JSON `MessageEvent`).
/// String pointer valid only during invocation.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_message(
    handle: *mut ManyMatrixClient,
    callback: MessageCallback,
) {
    let client = &*handle;
    client.on_message(move |msg| {
        if let Ok(json) = serde_json::to_string(&msg) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.as_ptr());
            }
        }
    });
}

/// Register a callback for incoming reactions (JSON `ReactionEvent`).
/// String pointer valid only during invocation.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_reaction(
    handle: *mut ManyMatrixClient,
    callback: ReactionCallback,
) {
    let client = &*handle;
    client.on_reaction(move |reaction| {
        if let Ok(json) = serde_json::to_string(&reaction) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.as_ptr());
            }
        }
    });
}

/// Register a callback for read receipts (JSON `ReceiptEvent`).
/// String pointer valid only during invocation.
///
/// # Safety
/// `handle` must be a valid ManyMatrixClient pointer. `callback` must remain
/// valid for the lifetime of the client.
#[no_mangle]
pub unsafe extern "C" fn manymatrix_on_receipt(
    handle: *mut ManyMatrixClient,
    callback: ReceiptCallback,
) {
    let client = &*handle;
    client.on_receipt(move |receipt| {
        if let Ok(json) = serde_json::to_string(&receipt) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.as_ptr());
            }
        }
    });
}
