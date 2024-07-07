use std::path::Path;

use matrix_sdk::matrix_auth::MatrixSession;
use serde::{Deserialize, Serialize};

/// Wrapper around [`MatrixSession`] that can be persisted to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSession {
    pub homeserver: String,
    #[serde(flatten)]
    pub session: MatrixSession,
}

impl StoredSession {
    pub fn save(&self, path: &Path) -> Result<(), crate::Error> {
        let json = serde_json::to_string_pretty(self)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, json)?;
        Ok(())
    }

    pub fn load(path: &Path) -> Result<Self, crate::Error> {
        let json = std::fs::read_to_string(path)?;
        Ok(serde_json::from_str(&json)?)
    }
}
