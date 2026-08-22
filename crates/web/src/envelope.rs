use serde::Serialize;

// The variant names are the wire format: the Dart web bridge matches on
// "MatrixSdkError" etc., and the FFI envelope uses the same strings.
#[allow(clippy::enum_variant_names)]
#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub enum ErrKind {
    MatrixSdkError,
    SerdeError,
    StorageError,
    PanicError,
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
