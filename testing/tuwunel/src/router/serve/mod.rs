mod plain;
#[cfg(feature = "direct_tls")]
mod tls;
mod unix;

use std::sync::Arc;

use axum_server::Handle as ServerHandle;
use tokio::sync::broadcast;
use tuwunel_core::{Result, err};
use tuwunel_service::Services;

use super::layers;

/// Serve clients
pub(super) async fn serve(
	services: Arc<Services>,
	handle: ServerHandle,
	mut shutdown: broadcast::Receiver<()>,
) -> Result {
	let server = &services.server;
	let config = &server.config;
	if !config.listening {
		return shutdown
			.recv()
			.await
			.map_err(|e| err!(error!("channel error: {e}")));
	}

	let addrs = config.get_bind_addrs();
	let (app, _guard) = layers::build(&services)?;
	if cfg!(unix) && config.unix_socket_path.is_some() {
		unix::serve(server, app, shutdown).await
	} else if config.tls.certs.is_some() {
		#[cfg(feature = "direct_tls")]
		services.globals.init_rustls_provider()?;
		#[cfg(feature = "direct_tls")]
		return tls::serve(server, app, handle, addrs).await;

		#[cfg(not(feature = "direct_tls"))]
		return tuwunel_core::Err!(Config(
			"tls",
			"tuwunel was not built with direct TLS support (\"direct_tls\")"
		));
	} else {
		plain::serve(server, app, handle, addrs).await
	}
}
