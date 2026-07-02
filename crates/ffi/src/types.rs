use std::ffi::{c_char, c_void, CString};

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
        let cstr = CString::new(s).unwrap_or_default();
        Self::success(cstr.into_raw() as *mut c_void)
    }

    /// Create an error result with a message.
    pub fn error(msg: &str) -> Self {
        let cstr = CString::new(msg).unwrap_or_default();
        Self {
            ok: false,
            data: std::ptr::null_mut(),
            error_msg: cstr.into_raw(),
        }
    }
}

/// Buffer for passing binary data (media) across the FFI boundary.
///
/// The caller must free this with `ffi_free_buffer`.
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
