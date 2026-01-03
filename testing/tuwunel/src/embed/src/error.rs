use thiserror::Error;

/// Embed crate errors.
#[derive(Debug, Error)]
pub enum EmbedError {
	/// Config error.
	#[error("configuration error: {0}")]
	Config(String),

	/// Startup failure.
	#[error("startup failed: {0}")]
	Startup(String),

	/// Request failure.
	#[error("request failed: {}", match .status {
		| Some(s) => format!("{s}: {}", .body),
		| None => .body.clone(),
	})]
	Request {
		status: Option<http::StatusCode>,
		body: String,
	},

	/// Shutdown failure.
	#[error("shutdown failed: {0}")]
	Shutdown(String),
}
