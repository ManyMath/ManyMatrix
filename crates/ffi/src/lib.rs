mod callbacks;
mod client;
mod crypto;
mod media;
mod messaging;
mod rooms;
mod types;

pub use callbacks::*;
pub use client::*;
pub use crypto::*;
pub use media::*;
pub use messaging::*;
pub use rooms::*;
pub use types::*;

use std::ffi::{c_char, CStr, CString};
use std::sync::LazyLock;
use tokio::runtime::Runtime;

/// Global Tokio runtime shared by all FFI functions.
static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("Failed to create Tokio runtime"));

/// Free an FfiResult, releasing the error message string if present.
///
/// # Safety
/// `result` must have been returned by one of the FFI functions in this crate.
#[no_mangle]
pub extern "C" fn ffi_free_result(result: FfiResult) {
    if !result.error_msg.is_null() {
        unsafe {
            drop(CString::from_raw(result.error_msg));
        }
    }
}

/// Free a heap-allocated C string returned by an FFI function.
///
/// # Safety
/// `s` must be a pointer previously returned as `data` in an `FfiResult`,
/// or null (in which case this is a no-op).
#[no_mangle]
pub unsafe extern "C" fn ffi_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Free an `FfiBuffer` returned as `data` in an `FfiResult`, releasing both
/// the byte array and the buffer struct itself.
///
/// # Safety
/// `buf` must be a pointer previously returned by one of the media FFI
/// functions in this crate, or null (in which case this is a no-op). It must
/// not be used again afterwards.
#[no_mangle]
pub unsafe extern "C" fn ffi_free_buffer(buf: *mut FfiBuffer) {
    if buf.is_null() {
        return;
    }
    let buf = Box::from_raw(buf);
    if !buf.data.is_null() {
        drop(Vec::from_raw_parts(buf.data, buf.len, buf.len));
    }
}

/// Convert a C string pointer to a Rust `&str`.
///
/// # Safety
/// The pointer must be non-null and point to a valid, NUL-terminated UTF-8 string.
pub(crate) unsafe fn str_from_ptr<'a>(ptr: *const c_char) -> &'a str {
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

/// Convert a nullable C string pointer to an `Option<&str>`.
///
/// # Safety
/// If non-null, the pointer must point to a valid, NUL-terminated UTF-8 string.
pub(crate) unsafe fn optional_str_from_ptr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        Some(str_from_ptr(ptr))
    }
}
