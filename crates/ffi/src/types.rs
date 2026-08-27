use std::ffi::{c_char, c_void, CString};

use serde::Serialize;

const FFI_ERROR_ENVELOPE_VERSION: u8 = 1;

#[derive(Serialize)]
struct FfiErrorEnvelope<'a> {
    manymatrix_ffi_error: u8,
    kind: &'a str,
    message: &'a str,
    details: serde_json::Value,
}

pub(crate) trait FfiErrorSource: std::fmt::Display {
    fn ffi_kind(&self) -> &'static str;

    fn ffi_details(&self) -> serde_json::Value {
        serde_json::json!({})
    }
}

impl FfiErrorSource for manymatrix_core::Error {
    fn ffi_kind(&self) -> &'static str {
        match self {
            manymatrix_core::Error::Json(_) | manymatrix_core::Error::IdParse(_) => "SerdeError",
            manymatrix_core::Error::Io(_) => "StorageError",
            _ => "MatrixSdkError",
        }
    }

    fn ffi_details(&self) -> serde_json::Value {
        self.details()
    }
}

impl FfiErrorSource for serde_json::Error {
    fn ffi_kind(&self) -> &'static str {
        "SerdeError"
    }
}

fn cstring_lossy(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new(s.replace('\0', "\\0")).unwrap_or_default())
}

fn ffi_error_envelope_json(
    kind: &str,
    message: &str,
    details: serde_json::Value,
) -> Option<String> {
    serde_json::to_string(&FfiErrorEnvelope {
        manymatrix_ffi_error: FFI_ERROR_ENVELOPE_VERSION,
        kind,
        message,
        details,
    })
    .ok()
}

/// Uniform result type for all FFI functions.
///
/// - `ok`: true on success, false on error
/// - `data`: opaque pointer to result data (may be null for void returns)
/// - `error_msg`: null on success, heap-allocated C string on error
///
/// The caller must free this with `ffi_free_result`.
#[repr(C)]
pub struct FfiResult {
    pub ok: bool,
    pub data: *mut c_void,
    pub error_msg: *mut c_char,
}

impl FfiResult {
    /// Create a successful result with an opaque data pointer.
    pub fn success(data: *mut c_void) -> Self {
        Self {
            ok: true,
            data,
            error_msg: std::ptr::null_mut(),
        }
    }

    /// Create a successful result with no data.
    pub fn success_void() -> Self {
        Self::success(std::ptr::null_mut())
    }

    /// Create a successful result containing a string.
    pub fn success_string(s: &str) -> Self {
        let cstr = cstring_lossy(s);
        Self::success(cstr.into_raw() as *mut c_void)
    }

    /// Create an error result with a message.
    pub fn error(msg: &str) -> Self {
        let cstr = cstring_lossy(msg);
        Self {
            ok: false,
            data: std::ptr::null_mut(),
            error_msg: cstr.into_raw(),
        }
    }

    /// Create a structured error result while preserving the existing C ABI.
    pub fn error_with_kind(kind: &str, message: &str, details: serde_json::Value) -> Self {
        match ffi_error_envelope_json(kind, message, details) {
            Some(json) => Self::error(&json),
            None => Self::error(message),
        }
    }

    /// Create a structured error result from a known SDK-side error type.
    pub(crate) fn error_from<E: FfiErrorSource + ?Sized>(error: &E) -> Self {
        Self::error_with_kind(error.ffi_kind(), &error.to_string(), error.ffi_details())
    }

    /// Create a structured validation/serialization error from an ad-hoc message.
    pub(crate) fn serde_error(message: &str) -> Self {
        Self::error_with_kind("SerdeError", message, serde_json::json!({}))
    }

    /// Create a structured local storage/state error from an ad-hoc message.
    pub(crate) fn storage_error(message: &str) -> Self {
        Self::error_with_kind("StorageError", message, serde_json::json!({}))
    }
}

/// Buffer for passing binary data (media) across the FFI boundary.
///
/// Returned as a heap-allocated pointer in `FfiResult.data`; the caller must
/// pass that pointer to `ffi_free_buffer`.
#[repr(C)]
pub struct FfiBuffer {
    pub data: *mut u8,
    pub len: usize,
}

/// Callback type for incoming message events. Receives JSON-serialized MessageEvent.
///
/// **Lifetime contract:** the pointer is heap-allocated and owned by the receiver.
/// `NativeCallable.listener` (the Dart-side registration mechanism) posts this call
/// across isolates and returns before the target isolate reads the pointee, so a
/// pointer valid only for the invocation's duration is not safe here: the receiver
/// must free the pointer with `ffi_free_string` once done reading it.
pub type MessageCallback = extern "C" fn(*mut c_char);

/// Callback type for incoming reaction events. Receives JSON-serialized ReactionEvent.
/// Same ownership contract as [`MessageCallback`].
pub type ReactionCallback = extern "C" fn(*mut c_char);

/// Callback type for incoming receipt events. Receives JSON-serialized ReceiptEvent.
/// Same ownership contract as [`MessageCallback`].
pub type ReceiptCallback = extern "C" fn(*mut c_char);

/// Callback type for incoming custom (non-standard) message-like events. Receives
/// JSON-serialized CustomEvent. Same ownership contract as [`MessageCallback`].
pub type CustomEventCallback = extern "C" fn(*mut c_char);

/// Callback type for sync-loop status events. Failed exits include the legacy
/// `error` string plus structured `errorKind` and `errorDetails` fields. Same
/// ownership contract as [`MessageCallback`].
pub type SyncStatusCallback = extern "C" fn(*mut c_char);

/// Callback type for refreshed session JSON updates. Same ownership contract
/// as [`MessageCallback`].
pub type SessionUpdateCallback = extern "C" fn(*mut c_char);

#[cfg(test)]
mod tests {
    use super::FfiResult;
    use std::ffi::CString;

    fn take_error_message(result: FfiResult) -> String {
        assert!(!result.ok);
        assert!(!result.error_msg.is_null());
        unsafe { CString::from_raw(result.error_msg) }
            .into_string()
            .expect("FFI error should be valid UTF-8")
    }

    #[test]
    fn error_from_core_error_uses_structured_envelope_without_abi_change() {
        let error = manymatrix_core::Error::IdParse("bad room id".to_string());
        let message = take_error_message(FfiResult::error_from(&error));
        let parsed: serde_json::Value = serde_json::from_str(&message).unwrap();

        assert_eq!(parsed["manymatrix_ffi_error"], 1);
        assert_eq!(parsed["kind"], "SerdeError");
        assert_eq!(parsed["message"], "ID parse error: bad room id");
        assert!(parsed["details"].as_object().unwrap().is_empty());
    }

    #[test]
    fn error_with_kind_preserves_matrix_sdk_details() {
        let message = take_error_message(FfiResult::error_with_kind(
            "MatrixSdkError",
            "[403 / M_FORBIDDEN] invite denied",
            serde_json::json!({
                "status_code": 403,
                "errcode": "M_FORBIDDEN",
            }),
        ));
        let parsed: serde_json::Value = serde_json::from_str(&message).unwrap();

        assert_eq!(parsed["manymatrix_ffi_error"], 1);
        assert_eq!(parsed["kind"], "MatrixSdkError");
        assert_eq!(parsed["details"]["status_code"], 403);
        assert_eq!(parsed["details"]["errcode"], "M_FORBIDDEN");
    }
}
