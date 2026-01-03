use clap::Subcommand;
use futures::StreamExt;
use ruma::{OwnedRoomAliasId, OwnedRoomId};
use tuwunel_core::Result;

use crate::Context;

#[derive(Debug, Subcommand)]
/// All the getters and iterators from src/database/key_value/rooms/alias.rs
pub(crate) enum RoomAliasCommand {
	/// - Resolve any local or remote alias.
	ResolveAlias {
		/// Full room alias
		alias: OwnedRoomAliasId,
	},

	/// - Resolve an alias on this server.
	ResolveLocalAlias {
		/// Full room alias
		alias: OwnedRoomAliasId,
	},

	/// - Iterator of all our local room aliases for the room ID
	LocalAliasesForRoom {
		/// Full room ID
		room_id: OwnedRoomId,
	},

	/// - Iterator of all our local aliases in our database with their room IDs
	AllLocalAliases,
}

/// All the getters and iterators in src/database/key_value/rooms/alias.rs
pub(super) async fn process(subcommand: RoomAliasCommand, context: &Context<'_>) -> Result {
	let services = context.services;

	match subcommand {
		| RoomAliasCommand::ResolveAlias { alias } => {
			let timer = tokio::time::Instant::now();
			let results = services.alias.resolve_alias(&alias).await;
			let query_time = timer.elapsed();

			write!(context, "Query completed in {query_time:?}:\n\n```rs\n{results:#?}\n```")
		},
		| RoomAliasCommand::ResolveLocalAlias { alias } => {
			let timer = tokio::time::Instant::now();
			let results = services.alias.resolve_local_alias(&alias).await;
			let query_time = timer.elapsed();

			write!(context, "Query completed in {query_time:?}:\n\n```rs\n{results:#?}\n```")
		},
		| RoomAliasCommand::LocalAliasesForRoom { room_id } => {
			let timer = tokio::time::Instant::now();
			let aliases: Vec<_> = services
				.alias
				.local_aliases_for_room(&room_id)
				.map(ToOwned::to_owned)
				.collect()
				.await;
			let query_time = timer.elapsed();

			write!(context, "Query completed in {query_time:?}:\n\n```rs\n{aliases:#?}\n```")
		},
		| RoomAliasCommand::AllLocalAliases => {
			let timer = tokio::time::Instant::now();
			let aliases = services
				.alias
				.all_local_aliases()
				.map(|(room_id, alias)| (room_id.to_owned(), alias.to_owned()))
				.collect::<Vec<_>>()
				.await;
			let query_time = timer.elapsed();

			write!(context, "Query completed in {query_time:?}:\n\n```rs\n{aliases:#?}\n```")
		},
	}
	.await
}
