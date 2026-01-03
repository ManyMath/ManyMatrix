//! Load test scenario: concurrent clients register, login, join a
//! shared room, and send messages.

use super::common::{
	MatrixClient, DEFAULT_PASSWORD, REGISTRATION_TOKEN, SERVER_NAME,
};

/// Entry point for the load-test subcommand.
pub async fn run_load_test(
	server_url: &str,
	role: &str,
	client_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let username = format!("loaduser-{client_id}");
	match role {
		| "creator" => run_creator(server_url, &username).await,
		| "joiner" => run_joiner(server_url, &username).await,
		| other => Err(format!(
			"unknown role: {other} (expected creator or joiner)"
		)
		.into()),
	}
}

/// Creator flow: register, login, create room with alias, send
/// message.
async fn run_creator(
	server_url: &str,
	username: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("{username}: starting load-test creator flow");

	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			username,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;

	client.login_user(username, DEFAULT_PASSWORD).await?;

	let room_id =
		client.create_room(Some("load-test")).await?;
	eprintln!(
		"{username}: created room {room_id} \
		 with alias #load-test:{SERVER_NAME}"
	);

	client
		.send_text_message(
			&room_id,
			&format!("load-test message from {username}"),
		)
		.await?;

	eprintln!(
		"{username}: load-test creator scenario complete"
	);
	Ok(())
}

/// Joiner flow: register, login, join room by alias, send message.
async fn run_joiner(
	server_url: &str,
	username: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("{username}: starting load-test joiner flow");

	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			username,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;

	client.login_user(username, DEFAULT_PASSWORD).await?;

	let room_alias =
		format!("#load-test:{SERVER_NAME}");
	let room_id = client
		.join_room_with_retry(&room_alias, 60, 1000)
		.await?;
	eprintln!("{username}: joined room {room_id}");

	client
		.send_text_message(
			&room_id,
			&format!("load-test message from {username}"),
		)
		.await?;

	eprintln!(
		"{username}: load-test joiner scenario complete"
	);
	Ok(())
}
