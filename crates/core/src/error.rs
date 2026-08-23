#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("matrix SDK error: {0}")]
    Sdk(#[from] matrix_sdk::Error),

    #[error("client build error: {0}")]
    ClientBuild(Box<matrix_sdk::ClientBuildError>),

    #[error("HTTP error: {0}")]
    Http(#[from] matrix_sdk::HttpError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("ID parse error: {0}")]
    IdParse(String),

    #[error("attachment is {actual_bytes} bytes; downloads are limited to {max_bytes} bytes")]
    MediaTooLarge {
        actual_bytes: usize,
        max_bytes: usize,
    },

    #[error("{0}")]
    Other(String),
}

impl From<matrix_sdk::ClientBuildError> for Error {
    fn from(error: matrix_sdk::ClientBuildError) -> Self {
        // Boxed so the variant does not dominate the size of every `Result`.
        Self::ClientBuild(Box::new(error))
    }
}

impl Error {
    /// Structured metadata suitable for plugin error envelopes.
    ///
    /// Matrix homeserver failures expose `status_code` and `errcode` through
    /// matrix-sdk/Ruma. Keeping those fields here lets each bridge transport
    /// forward them without clients having to parse display strings.
    pub fn details(&self) -> serde_json::Value {
        match self {
            Self::Sdk(error) => error
                .as_client_api_error()
                .map(client_api_error_details)
                .unwrap_or_else(|| serde_json::json!({})),
            Self::Http(error) => error
                .as_client_api_error()
                .map(client_api_error_details)
                .unwrap_or_else(|| serde_json::json!({})),
            Self::MediaTooLarge {
                actual_bytes,
                max_bytes,
            } => serde_json::json!({
                "reason": "media_too_large",
                "actual_bytes": actual_bytes,
                "max_bytes": max_bytes,
            }),
            _ => serde_json::json!({}),
        }
    }
}

fn client_api_error_details(error: &matrix_sdk::ruma::api::client::Error) -> serde_json::Value {
    let mut details = serde_json::Map::new();
    details.insert(
        "status_code".to_string(),
        serde_json::Value::from(error.status_code.as_u16()),
    );
    if let Some(kind) = error.error_kind() {
        details.insert(
            "errcode".to_string(),
            serde_json::Value::String(kind.errcode().to_string()),
        );
    }
    serde_json::Value::Object(details)
}

#[cfg(test)]
mod tests {
    use super::client_api_error_details;
    use matrix_sdk::ruma::api::client::error::{ErrorBody, ErrorKind, StandardErrorBody};
    use matrix_sdk::ruma::api::client::Error as ClientApiError;
    use matrix_sdk::ruma::exports::http::StatusCode;

    #[test]
    fn client_api_error_details_include_status_and_errcode() {
        let error = ClientApiError::new(
            StatusCode::NOT_FOUND,
            ErrorBody::Standard(StandardErrorBody::new(
                ErrorKind::NotFound,
                "not found".to_string(),
            )),
        );

        let details = client_api_error_details(&error);

        assert_eq!(details["status_code"], 404);
        assert_eq!(details["errcode"], "M_NOT_FOUND");
    }
}
