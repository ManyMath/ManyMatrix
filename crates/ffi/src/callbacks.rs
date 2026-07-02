use std::ffi::CString;

use crate::client::{client_from_handle, ManyMatrixClient};
use crate::types::{MessageCallback, ReactionCallback, ReceiptCallback};

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
    let client = client_from_handle(handle);
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
    let client = client_from_handle(handle);
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
    let client = client_from_handle(handle);
    client.on_receipt(move |receipt| {
        if let Ok(json) = serde_json::to_string(&receipt) {
            if let Ok(cstr) = CString::new(json) {
                callback(cstr.into_raw());
            }
        }
    });
}
