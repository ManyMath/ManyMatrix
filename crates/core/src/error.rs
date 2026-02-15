#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("matrix SDK error: {0}")]
    Sdk(#[from] matrix_sdk::Error),

    #[error("client build error: {0}")]
    ClientBuild(#[from] matrix_sdk::ClientBuildError),

    #[error("HTTP error: {0}")]
    Http(#[from] matrix_sdk::HttpError),

    #[cfg(not(target_family = "wasm"))]
    #[error("request error: {0}")]
    Reqwest(#[from] reqwest::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("ID parse error: {0}")]
    IdParse(String),

    #[error("{0}")]
    Other(String),
}
