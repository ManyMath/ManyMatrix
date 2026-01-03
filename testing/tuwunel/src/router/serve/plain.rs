use std::{
	net::SocketAddr,
	sync::{Arc, atomic::Ordering},
};

use axum::Router;
use axum_server::{Handle as ServerHandle, bind};
use tokio::task::JoinSet;
use tuwunel_core::{Result, Server, debug_info, info};

pub(super) async fn serve(
	server: &Arc<Server>,
	router: Router,
	handle: ServerHandle,
	addrs: Vec<SocketAddr>,
) -> Result {
	let mut join_set = JoinSet::new();
	let router = router.into_make_service_with_connect_info::<SocketAddr>();
	for addr in &addrs {
		let bound = bind(*addr);
		let handler = bound.handle(handle.clone());
		let acceptor = handler.serve(router.clone());
		join_set.spawn_on(acceptor, server.runtime());
	}

	info!("Listening on {addrs:?}");
	while join_set.join_next().await.is_some() {}

	let handle_active = server
		.metrics
		.requests_handle_active
		.load(Ordering::Acquire);

	debug_info!(
		handle_finished = server
			.metrics
			.requests_handle_finished
			.load(Ordering::Acquire),
		panics = server
			.metrics
			.requests_panic
			.load(Ordering::Acquire),
		handle_active,
		"Stopped listening on {addrs:?}",
	);

	debug_assert_eq!(0, handle_active, "active request handles still pending");

	Ok(())
}
