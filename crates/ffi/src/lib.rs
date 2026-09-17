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

/// Return early from an FFI function with the `FfiResult` carried by `Err`.
macro_rules! ffi_try {
    ($expr:expr) => {
        match $expr {
            Ok(value) => value,
            Err(result) => return result,
        }
    };
}
pub(crate) use ffi_try;

/// Convert a required C string argument to a Rust `&str`.
///
/// A null pointer or invalid UTF-8 becomes a `SerdeError` result for the
/// caller. Silently substituting `""` would, for example, send an empty
/// message or attempt a login with an empty password.
///
/// # Safety
/// If non-null, the pointer must point to a NUL-terminated string that stays
/// valid for `'a`.
pub(crate) unsafe fn str_from_ptr<'a>(ptr: *const c_char) -> Result<&'a str, FfiResult> {
    if ptr.is_null() {
        return Err(FfiResult::serde_error("required string argument is null"));
    }
    CStr::from_ptr(ptr).to_str().map_err(|error| {
        FfiResult::serde_error(&format!("string argument is not valid UTF-8: {error}"))
    })
}

/// Convert a nullable C string argument to an `Option<&str>`.
///
/// # Safety
/// If non-null, the pointer must point to a NUL-terminated string that stays
/// valid for `'a`.
pub(crate) unsafe fn optional_str_from_ptr<'a>(
    ptr: *const c_char,
) -> Result<Option<&'a str>, FfiResult> {
    if ptr.is_null() {
        Ok(None)
    } else {
        str_from_ptr(ptr).map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::{optional_str_from_ptr, str_from_ptr};
    use crate::types::FfiResult;
    use std::ffi::{c_char, CString};

    fn error_kind(result: FfiResult) -> String {
        assert!(!result.ok);
        let message = unsafe { CString::from_raw(result.error_msg) }
            .into_string()
            .unwrap();
        let envelope: serde_json::Value = serde_json::from_str(&message).unwrap();
        envelope["kind"].as_str().unwrap().to_owned()
    }

    #[test]
    fn required_strings_reject_null_and_invalid_utf8() {
        let null = unsafe { str_from_ptr(std::ptr::null()) }.unwrap_err();
        assert_eq!(error_kind(null), "SerdeError");

        let invalid = b"\xff\xfe\0";
        let invalid = unsafe { str_from_ptr(invalid.as_ptr() as *const c_char) }.unwrap_err();
        assert_eq!(error_kind(invalid), "SerdeError");

        let valid = CString::new("hello").unwrap();
        assert_eq!(unsafe { str_from_ptr(valid.as_ptr()) }.ok(), Some("hello"));
    }

    #[test]
    fn optional_strings_allow_null_but_still_reject_invalid_utf8() {
        assert_eq!(
            unsafe { optional_str_from_ptr(std::ptr::null()) }.ok(),
            Some(None)
        );
        let invalid = b"\xff\0";
        let invalid =
            unsafe { optional_str_from_ptr(invalid.as_ptr() as *const c_char) }.unwrap_err();
        assert_eq!(error_kind(invalid), "SerdeError");
    }

    #[test]
    fn null_client_handles_are_reported_instead_of_dereferenced() {
        let body = CString::new("hi").unwrap();
        let room = CString::new("!room:example.org").unwrap();
        let result = unsafe {
            crate::messaging::manymatrix_send_text(
                std::ptr::null_mut(),
                room.as_ptr(),
                body.as_ptr(),
            )
        };
        assert_eq!(error_kind(result), "StorageError");
    }
}
