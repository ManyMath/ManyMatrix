use std::{process::ExitCode, time::Duration};

use anyhow::{bail, Context, Result};
use manymatrix_core::ManyMatrixClient;
use matrix_sdk::ruma::api::client::room::create_room::v3::Request as CreateRoomRequest;
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::events::room::message::SyncRoomMessageEvent;
use shadow_common::{LATENCY_ENCRYPTED_MESSAGE_TEXT, LATENCY_MESSAGE_TEXT};
use tokio::sync::mpsc;

const DEFAULT_PASSWORD: &str = "shadow_test_pass";
const REGISTRATION_TOKEN: &str = "shadow_test_token";
const ROOM_ALIAS_FULL: &str = "#shadow-latency-room:tuwunel-server";
const ROOM_ALIAS_LOCALPART: &str = "shadow-latency-room";
const SHADOW_SYNC_TIMEOUT: Duration = Duration::from_secs(1);

struct Args {
    subcommand: String,
    server_url: String,
    role: String,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match async_main().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("shadow-client failed: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn async_main() -> Result<()> {
    let args = parse_args()?;

    match args.subcommand.as_str() {
        "latency-message" => run_latency_message(&args.server_url, &args.role).await,
        "latency-encrypted-message" => {
            run_latency_encrypted_message(&args.server_url, &args.role).await
        }
        other => bail!("unsupported shadow-client subcommand: {other}"),
    }
}

fn parse_args() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let subcommand = args.next().context("missing shadow-client subcommand")?;
    let mut server_url = None;
    let mut role = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--server-url" => {
                server_url = Some(args.next().context("missing value for --server-url")?)
            }
            "--role" => role = Some(args.next().context("missing value for --role")?),
            other => bail!("unknown shadow-client argument: {other}"),
        }
    }

    Ok(Args {
        subcommand,
        server_url: server_url.context("missing required --server-url")?,
        role: role.context("missing required --role")?,
    })
}

async fn run_latency_message(server_url: &str, role: &str) -> Result<()> {
    wait_for_server(server_url, 60, 500).await?;

    match role {
        "alice" => run_alice(server_url).await,
        "bob" => run_bob(server_url).await,
        other => bail!("unsupported latency-message role: {other}"),
    }
}

async fn run_latency_encrypted_message(server_url: &str, role: &str) -> Result<()> {
    wait_for_server(server_url, 60, 500).await?;

    match role {
        "alice" => run_alice_encrypted(server_url).await,
        "bob" => run_bob_encrypted(server_url).await,
        other => bail!("unsupported latency-encrypted-message role: {other}"),
    }
}

async fn run_alice(server_url: &str) -> Result<()> {
    register_user_via_api(
        server_url,
        "alice",
        DEFAULT_PASSWORD,
        Some(REGISTRATION_TOKEN),
    )
    .await?;

    let store = tempfile::tempdir().context("failed to create Alice store dir")?;
    let client = ManyMatrixClient::new(server_url, store.path()).await?;
    client.login("alice", DEFAULT_PASSWORD).await?;

    let mut request = CreateRoomRequest::new();
    request.name = Some("Shadow Latency Room".to_owned());
    request.room_alias_name = Some(ROOM_ALIAS_LOCALPART.to_owned());
    request.visibility = Visibility::Public;

    let room_id = client
        .inner()
        .create_room(request)
        .await?
        .room_id()
        .to_owned();
    eprintln!("alice: created room {room_id}");

    client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;
    tokio::time::sleep(Duration::from_secs(5)).await;
    client
        .send_text(room_id.as_str(), LATENCY_MESSAGE_TEXT)
        .await?;
    eprintln!("alice: sent message {LATENCY_MESSAGE_TEXT}");

    Ok(())
}

async fn run_bob(server_url: &str) -> Result<()> {
    register_user_via_api(
        server_url,
        "bob",
        DEFAULT_PASSWORD,
        Some(REGISTRATION_TOKEN),
    )
    .await?;

    let store = tempfile::tempdir().context("failed to create Bob store dir")?;
    let client = ManyMatrixClient::new(server_url, store.path()).await?;
    client.login("bob", DEFAULT_PASSWORD).await?;

    let room_id =
        join_room_with_retry(&client, ROOM_ALIAS_FULL, 30, Duration::from_secs(1)).await?;
    eprintln!("bob: joined room {room_id}");

    let (tx, mut rx) = mpsc::channel::<String>(16);
    let observed_room_id = room_id.clone();
    client
        .inner()
        .add_event_handler(move |event: SyncRoomMessageEvent, room: matrix_sdk::Room| {
            let tx = tx.clone();
            let observed_room_id = observed_room_id.clone();

            async move {
                if room.room_id().as_str() != observed_room_id {
                    return;
                }

                if let SyncRoomMessageEvent::Original(message) = event {
                    let _ = tx.send(message.content.body().to_owned()).await;
                }
            }
        });

    for attempt in 0..20 {
        client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;

        if let Ok(Some(message)) = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await {
            if message == LATENCY_MESSAGE_TEXT {
                eprintln!("bob: received message {message}");
                return Ok(());
            }
        }

        eprintln!("bob: waiting for message (attempt {attempt})");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    bail!("bob did not receive expected message: {LATENCY_MESSAGE_TEXT}")
}

async fn run_alice_encrypted(server_url: &str) -> Result<()> {
    register_user_via_api(
        server_url,
        "alice",
        DEFAULT_PASSWORD,
        Some(REGISTRATION_TOKEN),
    )
    .await?;

    let store = tempfile::tempdir().context("failed to create Alice store dir")?;
    let client = ManyMatrixClient::new(server_url, store.path()).await?;
    client.login("alice", DEFAULT_PASSWORD).await?;

    let mut request = CreateRoomRequest::new();
    request.name = Some("Shadow Encrypted Room".to_owned());
    request.room_alias_name = Some(ROOM_ALIAS_LOCALPART.to_owned());
    request.visibility = Visibility::Public;

    let room_id = client
        .inner()
        .create_room(request)
        .await?
        .room_id()
        .to_owned();
    eprintln!("alice: created encrypted room {room_id}");

    client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;

    for attempt in 0..30 {
        client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;
        let members = client.room_members(room_id.as_str()).await?;
        if members.len() >= 2 {
            eprintln!("alice: bob joined encrypted room on attempt {attempt}");
            break;
        }
        if attempt == 29 {
            bail!("alice: bob never joined encrypted room {room_id}");
        }
        eprintln!("alice: waiting for bob to join encrypted room (attempt {attempt})");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    client.enable_encryption(room_id.as_str()).await?;
    eprintln!("alice: enabled room encryption");

    for attempt in 0..12 {
        client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;
        eprintln!("alice: waiting for Bob device discovery attempt {attempt}");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    client
        .send_text(room_id.as_str(), LATENCY_ENCRYPTED_MESSAGE_TEXT)
        .await?;
    eprintln!("alice: sent encrypted message {LATENCY_ENCRYPTED_MESSAGE_TEXT}");

    Ok(())
}

async fn run_bob_encrypted(server_url: &str) -> Result<()> {
    register_user_via_api(
        server_url,
        "bob",
        DEFAULT_PASSWORD,
        Some(REGISTRATION_TOKEN),
    )
    .await?;

    let store = tempfile::tempdir().context("failed to create Bob store dir")?;
    let client = ManyMatrixClient::new(server_url, store.path()).await?;
    client.login("bob", DEFAULT_PASSWORD).await?;

    let room_id =
        join_room_with_retry(&client, ROOM_ALIAS_FULL, 30, Duration::from_secs(1)).await?;
    eprintln!("bob: joined encrypted room {room_id}");

    for attempt in 0..20 {
        client.sync_once_with_timeout(SHADOW_SYNC_TIMEOUT).await?;
        let messages = client.get_messages(room_id.as_str(), None, 20).await?;
        if messages
            .messages
            .iter()
            .any(|message| message.body == LATENCY_ENCRYPTED_MESSAGE_TEXT)
        {
            eprintln!("bob: received encrypted message {LATENCY_ENCRYPTED_MESSAGE_TEXT}");
            return Ok(());
        }

        eprintln!("bob: waiting for encrypted message (attempt {attempt})");
        tokio::time::sleep(Duration::from_millis(750)).await;
    }

    bail!("bob did not receive expected encrypted message: {LATENCY_ENCRYPTED_MESSAGE_TEXT}")
}

async fn join_room_with_retry(
    client: &ManyMatrixClient,
    room_id_or_alias: &str,
    max_attempts: u32,
    interval: Duration,
) -> Result<String> {
    for attempt in 0..max_attempts {
        match client.join_room(room_id_or_alias).await {
            Ok(room_id) => return Ok(room_id),
            Err(error) => {
                eprintln!("join attempt {attempt} failed: {error}");
                tokio::time::sleep(interval).await;
            }
        }
    }

    bail!("failed to join room after {max_attempts} attempts: {room_id_or_alias}")
}

async fn wait_for_server(base_url: &str, max_retries: u32, retry_interval_ms: u64) -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .context("failed to build readiness HTTP client")?;
    let url = format!("{base_url}/_matrix/client/versions");
    let interval = Duration::from_millis(retry_interval_ms);

    for attempt in 0..max_retries {
        match client.get(&url).send().await {
            Ok(response) if response.status().is_success() => {
                let body = response
                    .text()
                    .await
                    .context("readiness response was not text")?;
                let json: serde_json::Value =
                    serde_json::from_str(&body).context("readiness response was not JSON")?;
                if json.get("versions").is_some() {
                    eprintln!("server ready after {attempt} retries");
                    return Ok(());
                }
            }
            Ok(response) => eprintln!(
                "server readiness attempt {attempt}: HTTP {}",
                response.status()
            ),
            Err(error) => eprintln!("server readiness attempt {attempt}: {error}"),
        }

        tokio::time::sleep(interval).await;
    }

    bail!("server did not become ready at {base_url}")
}

async fn register_user_via_api(
    base_url: &str,
    username: &str,
    password: &str,
    registration_token: Option<&str>,
) -> Result<()> {
    let http = reqwest::Client::new();
    let url = format!("{base_url}/_matrix/client/v3/register");

    let initial_body = serde_json::json!({
        "username": username,
        "password": password,
        "auth": { "type": "m.login.dummy" },
        "inhibit_login": false,
    });

    let initial_response = http
        .post(&url)
        .json(&initial_body)
        .send()
        .await
        .context("registration request failed")?;
    let initial_status = initial_response.status();
    let initial_json: serde_json::Value = initial_response
        .json()
        .await
        .context("registration response was not JSON")?;

    if initial_status.is_success() {
        eprintln!("{username}: registered");
        return Ok(());
    }

    if initial_status != reqwest::StatusCode::UNAUTHORIZED {
        bail!("registration failed for {username}: {initial_status} {initial_json}");
    }

    let registration_token = registration_token.context("registration token required for UIAA")?;
    let session = initial_json["session"]
        .as_str()
        .context("registration challenge missing session")?;

    let token_body = serde_json::json!({
        "username": username,
        "password": password,
        "auth": {
            "type": "m.login.registration_token",
            "token": registration_token,
            "session": session,
        },
        "inhibit_login": false,
    });

    let token_response = http
        .post(&url)
        .json(&token_body)
        .send()
        .await
        .context("registration token request failed")?;
    let token_status = token_response.status();
    let token_json: serde_json::Value = token_response
        .json()
        .await
        .context("registration token response was not JSON")?;

    if !token_status.is_success() {
        bail!("registration failed for {username}: {token_status} {token_json}");
    }

    eprintln!("{username}: registered");
    Ok(())
}
