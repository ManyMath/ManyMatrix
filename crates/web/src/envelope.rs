use serde::Serialize;

// The variant names are the wire format: the Dart web bridge matches on
// "MatrixSdkError" etc., and the FFI envelope uses the same strings.
#[allow(clippy::enum_variant_names)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "PascalCase")]
pub enum ErrKind {
    MatrixSdkError,
    SerdeError,
    StorageError,
    PanicError,
}

impl ErrKind {
    /// Classify a core error the same way the native FFI bridge does, so a
    /// Dart app sees one exception type per failure regardless of transport.
    pub fn for_core_error(error: &manymatrix_core::Error) -> Self {
        match error {
            manymatrix_core::Error::Json(_) | manymatrix_core::Error::IdParse(_) => {
                Self::SerdeError
            }
            manymatrix_core::Error::Io(_) => Self::StorageError,
            _ => Self::MatrixSdkError,
        }
    }

    /// The wire name used in error envelopes and sync status payloads.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MatrixSdkError => "MatrixSdkError",
            Self::SerdeError => "SerdeError",
            Self::StorageError => "StorageError",
            Self::PanicError => "PanicError",
        }
    }
}

#[derive(Serialize)]
pub struct ErrEnvelope {
    pub kind: ErrKind,
    pub message: String,
    pub details: serde_json::Value,
}

#[derive(Serialize)]
#[serde(untagged)]
pub enum Envelope<T: Serialize> {
    Ok { ok: T },
    Err { err: ErrEnvelope },
}
