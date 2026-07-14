//! Native-side actor for the web/extension E2E harness (Phase 25).
//!
//! Registers test users on an embedded or hosted homeserver, one for the browser
//! under test, one for itself, then logs in through `manymatrix-core` and
//! executes commands received as JSON lines on stdin, replying with JSON
//! lines on stdout. Driven by `testing/web-e2e/run.mjs`.
//!
//! Protocol (one JSON object per line):
//! - startup:  `{"ready":true,"base_url":...,"actor_user_id":...,"ext_localpart":...,"ext_password":...,"ext_user_id":...}`
//! - request:  `{"id":1,"cmd":"join","room_id":"!..."}`
//! - response: `{"id":1,"ok":true}` or `{"id":1,"ok":false,"error":"..."}`
//!
//! Commands: `join`, `send_text`, `send_media`, `react`, `receipt`,
//! `create_invite`, `stop`.

use anyhow::{bail, Context, Result};
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient};
use test_harness::{ServerKind, TestHomeserver};
use tokio::io::{AsyncBufReadExt, BufReader};
use tracing_subscriber::EnvFilter;

const EXT_PASSWORD: &str = "manymatrix-web-e2e-ext";
const ACTOR_PASSWORD: &str = "manymatrix-web-e2e-actor";

fn emit(value: &serde_json::Value) {
    println!("{value}");
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    let kind = match std::env::args().nth(1).as_deref() {
        #[cfg(feature = "embedded-tests")]
        Some("embedded") => ServerKind::TuwunelEmbedded,
        #[cfg(feature = "hosted-tests")]
        Some("hosted-synapse") => ServerKind::HostedSynapse,
        #[cfg(feature = "hosted-tests")]
        Some("hosted-tuwunel") => ServerKind::HostedTuwunel,
        other => {
            bail!("usage: web_e2e_actor <embedded|hosted-synapse|hosted-tuwunel>, got {other:?}")
        }
    };

    let server = TestHomeserver::start(kind).await?;
    eprintln!(
        "[actor] {} ready at {}",
        server.server_kind(),
        server.base_url()
    );

    let ext = server.register_user("webext", EXT_PASSWORD).await?;
    let ext_second = server.register_user("webext2", EXT_PASSWORD).await?;
    let actor_reg = server.register_user("webactor", ACTOR_PASSWORD).await?;

    let store = tempfile::tempdir()?;
    let actor = ManyMatrixClient::new(server.base_url(), store.path()).await?;
    actor.login(&actor_reg.localpart, ACTOR_PASSWORD).await?;

    emit(&serde_json::json!({
        "ready": true,
        "base_url": server.base_url(),
        "actor_user_id": actor_reg.user_id,
        "ext_localpart": ext.localpart,
        "ext_password": EXT_PASSWORD,
        "ext_user_id": ext.user_id,
        "second_localpart": ext_second.localpart,
        "second_password": EXT_PASSWORD,
        "second_user_id": ext_second.user_id,
    }));

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let request: serde_json::Value =
            serde_json::from_str(line).with_context(|| format!("bad request line: {line}"))?;
        let id = request["id"].clone();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_owned();

        if cmd == "stop" {
            emit(&serde_json::json!({"id": id, "ok": true}));
            break;
        }

        match run_command(&actor, &cmd, &request).await {
            Ok(mut reply) => {
                reply["id"] = id;
                reply["ok"] = serde_json::json!(true);
                emit(&reply);
            }
            Err(error) => {
                emit(&serde_json::json!({
                    "id": id,
                    "ok": false,
                    "error": format!("{error:#}"),
                }));
            }
        }
    }

    // Leaves and forgets every room both registered users joined.
    server.stop().await?;
    eprintln!("[actor] stopped, cleanup done");
    Ok(())
}

async fn run_command(
    actor: &ManyMatrixClient,
    cmd: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    let field = |name: &str| -> Result<&str> {
        request[name]
            .as_str()
            .with_context(|| format!("command {cmd} missing field {name}"))
    };

    match cmd {
        "join" => {
            actor.join_room(field("room_id")?).await?;
            Ok(serde_json::json!({}))
        }
        "send_text" => {
            let event_id = actor.send_text(field("room_id")?, field("body")?).await?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "thread_reply" => {
            let thread_root_event_id = field("thread_root_event_id")?;
            let in_reply_to_event_id = request["in_reply_to_event_id"]
                .as_str()
                .unwrap_or(thread_root_event_id);
            let event_id = actor
                .send_thread_reply(
                    field("room_id")?,
                    thread_root_event_id,
                    in_reply_to_event_id,
                    field("body")?,
                )
                .await?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "send_media" => {
            let event_id = actor
                .upload_media(
                    field("room_id")?,
                    field("filename")?,
                    field("mime_type")?,
                    field("body")?.as_bytes().to_vec(),
                )
                .await?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "react" => {
            let event_id = actor
                .send_reaction(field("room_id")?, field("event_id")?, field("key")?)
                .await?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "receipt" => {
            actor
                .send_read_receipt(field("room_id")?, field("event_id")?)
                .await?;
            Ok(serde_json::json!({}))
        }
        "create_invite" => {
            let room_id = actor
                .create_room(CreateRoomOptions {
                    name: Some("Actor invitation".to_owned()),
                    invite: vec![field("user_id")?.to_owned()],
                    ..CreateRoomOptions::default()
                })
                .await?;
            Ok(serde_json::json!({"room_id": room_id}))
        }
        other => bail!("unknown command: {other}"),
    }
}
