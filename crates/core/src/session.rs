#[cfg(not(target_family = "wasm"))]
use std::path::Path;

use matrix_sdk::authentication::matrix::MatrixSession;
use serde::{Deserialize, Serialize};

/// Wrapper around [`MatrixSession`] that can be persisted to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSession {
    pub homeserver: String,
    #[serde(flatten)]
    pub session: MatrixSession,
}

#[cfg(not(target_family = "wasm"))]
impl StoredSession {
    pub fn save(&self, path: &Path) -> Result<(), crate::Error> {
        let json = serde_json::to_string_pretty(self)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // The file holds the access and refresh tokens, so it must not be
        // readable by other local users. Truncate and write with 0600 on
        // Unix; other platforms fall back to the default permissions.
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        use std::io::Write;
        let mut file = options.open(path)?;
        // `mode` only applies when the file is created; an existing file
        // written by an older version keeps its permissions otherwise.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(json.as_bytes())?;
        Ok(())
    }

    pub fn load(path: &Path) -> Result<Self, crate::Error> {
        let json = std::fs::read_to_string(path)?;
        Ok(serde_json::from_str(&json)?)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::StoredSession;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn saved_sessions_are_private_to_the_owner() {
        let dir = std::env::temp_dir().join(format!("manymatrix-session-{}", std::process::id()));
        let path = dir.join("session.json");
        // Pre-create the file world-readable to prove save() tightens it.
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, "{}").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();

        let session: StoredSession = serde_json::from_value(serde_json::json!({
            "homeserver": "https://example.org",
            "user_id": "@alice:example.org",
            "device_id": "DEVICE",
            "access_token": "secret",
        }))
        .unwrap();
        session.save(&path).unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        let reloaded = StoredSession::load(&path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(mode, 0o600);
        assert_eq!(reloaded.homeserver, "https://example.org");
    }
}
