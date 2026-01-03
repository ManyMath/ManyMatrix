use clap::Subcommand;
use ruma::{OwnedDeviceId, OwnedUserId};
use tuwunel_core::Result;
use tuwunel_service::sync::into_connection_key;

use crate::{admin_command, admin_command_dispatch};

#[admin_command_dispatch]
#[derive(Debug, Subcommand)]
/// Query sync service state
pub(crate) enum SyncCommand {
	/// List sliding-sync connections.
	ListConnections,

	/// Show details of sliding sync connection by ID.
	ShowConnection {
		user_id: OwnedUserId,
		device_id: Option<OwnedDeviceId>,
		conn_id: Option<String>,
	},

	/// Drop connections for a user, device, or all.
	DropConnections {
		user_id: Option<OwnedUserId>,
		device_id: Option<OwnedDeviceId>,
		conn_id: Option<String>,
	},
}

#[admin_command]
pub(super) async fn list_connections(&self) -> Result {
	let connections = self.services.sync.list_loaded_connections().await;

	for connection_key in connections {
		self.write_str(&format!("{connection_key:?}\n"))
			.await?;
	}

	Ok(())
}

#[admin_command]
pub(super) async fn show_connection(
	&self,
	user_id: OwnedUserId,
	device_id: Option<OwnedDeviceId>,
	conn_id: Option<String>,
) -> Result {
	let key = into_connection_key(user_id, device_id, conn_id);
	let cache = self
		.services
		.sync
		.get_loaded_connection(&key)
		.await?;

	let out;
	{
		let cached = cache.lock().await;
		out = format!("{cached:#?}");
	};

	self.write_str(out.as_str()).await
}

#[admin_command]
pub(super) async fn drop_connections(
	&self,
	user_id: Option<OwnedUserId>,
	device_id: Option<OwnedDeviceId>,
	conn_id: Option<String>,
) -> Result {
	self.services
		.sync
		.clear_connections(
			user_id.as_deref(),
			device_id.as_deref(),
			conn_id.map(Into::into).as_ref(),
		)
		.await;

	Ok(())
}
