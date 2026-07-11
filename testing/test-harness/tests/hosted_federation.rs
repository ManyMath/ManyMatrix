#![cfg(feature = "hosted-tests")]

//! Real internet federation between the two permanently hosted homeservers
//! (`synapse.manymatrix.com` and `tuwunel.manymatrix.com`), as opposed to
//! Shadow's simulated-network federation test. This exercises COMP-06: a
//! room created on one hosted server, joined by alias from the other,
//! carrying a message across the open internet via server-to-server
//! federation rather than a shared homeserver or a simulated network.
//!
//! Requires `MANYMATRIX_HOSTED_*` env vars (see `testing/test-harness/src/lib.rs`);
//! run via `scripts/compatibility.sh hosted`.

use std::time::Duration;

use anyhow::{Context, Result};
use manymatrix_core::ManyMatrixClient;
use matrix_sdk::ruma::api::client::room::create_room::v3::Request as CreateRoomRequest;
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::events::room::message::SyncRoomMessageEvent;
use test_harness::{ServerKind, TestHomeserver};
use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

fn domain_of(user_id: &str) -> &str {
    user_id
        .split_once(':')
        .map(|(_, domain)| domain)
        .unwrap_or(user_id)
}

async fn finalize_servers(
    creator: TestHomeserver,
    joiner: TestHomeserver,
    run_result: Result<()>,
) -> Result<()> {
    let creator_stop = creator.stop().await;
    let joiner_stop = joiner.stop().await;

    if run_result.is_err() {
        if let Err(e) = &creator_stop {
            eprintln!("failed to stop creator homeserver after test failure: {e:#}");
        }
        if let Err(e) = &joiner_stop {
            eprintln!("failed to stop joiner homeserver after test failure: {e:#}");
        }
        return run_result;
    }

    creator_stop.context("failed to stop creator homeserver")?;
    joiner_stop.context("failed to stop joiner homeserver")?;
    run_result
}

/// Alice (on `creator_kind`) creates a public, aliased room; Bob (on
/// `joiner_kind`) joins it by full alias, a cross-domain join, which only
/// succeeds if the two servers can actually federate over the open
/// internet, and Alice sends a message Bob must receive via federation.
async fn federated_message(creator_kind: ServerKind, joiner_kind: ServerKind) -> Result<()> {
    let creator = TestHomeserver::start(creator_kind).await?;
    let joiner = TestHomeserver::start(joiner_kind).await?;
    eprintln!(
        "creator {:?} ready at {}, joiner {:?} ready at {}",
        creator.server_kind(),
        creator.base_url(),
        joiner.server_kind(),
        joiner.base_url()
    );

    let run_result = async {
        let alice_reg = creator.register_user("alice", "password1").await?;
        let bob_reg = joiner.register_user("bob", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(creator.base_url(), alice_store.path()).await?;
        alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(joiner.base_url(), bob_store.path()).await?;
        bob.login(&bob_reg.localpart, "password2").await?;

        // Alice creates a public, aliased room on her own server.
        let alias_localpart = format!("fed-{}", alice_reg.localpart);
        let mut req = CreateRoomRequest::new();
        req.name = Some("federation-test-room".to_owned());
        req.room_alias_name = Some(alias_localpart.clone());
        req.visibility = Visibility::Public;
        let create_resp = alice.inner().create_room(req).await?;
        let room_id = create_resp.room_id().to_owned();
        let full_alias = format!("#{alias_localpart}:{}", domain_of(&alice_reg.user_id));
        eprintln!("alice: created federated room {room_id} ({full_alias})");

        // Bob joins by full alias from a different homeserver entirely;
        // this only resolves and succeeds via real server-to-server
        // federation between the two hosted domains.
        let joined_room_id = join_room_with_retry(&bob, &full_alias, 30, Duration::from_secs(1))
            .await
            .with_context(|| {
                format!(
                    "bob ({}) failed to join {full_alias} on {} via federation",
                    domain_of(&bob_reg.user_id),
                    domain_of(&alice_reg.user_id)
                )
            })?;
        assert_eq!(joined_room_id, room_id.as_str());
        eprintln!("bob: joined {full_alias} via federation as {joined_room_id}");

        let (tx, mut rx) = mpsc::channel::<String>(16);
        bob.inner()
            .add_event_handler(move |ev: SyncRoomMessageEvent, _room: matrix_sdk::Room| {
                let tx = tx.clone();
                async move {
                    if let SyncRoomMessageEvent::Original(msg) = ev {
                        let _ = tx.send(msg.content.body().to_owned()).await;
                    }
                }
            });

        alice.sync_once().await?;
        alice
            .send_text(room_id.as_str(), "hello across the wire")
            .await?;
        eprintln!("alice: sent federated message");

        let received =
            receive_federated_message_with_retry(&bob, &mut rx, 30, Duration::from_secs(1))
                .await
                .context("timed out waiting for federated message")?;
        assert_eq!(received, "hello across the wire");
        eprintln!("bob: received federated message: {received}");

        Ok(())
    }
    .await;

    finalize_servers(creator, joiner, run_result).await
}

/// Polls `bob.sync_once()` until the awaited message shows up on `rx` or the
/// attempt budget runs out. A single `sync_once()` call only observes
/// whatever the server has to offer *at that moment*, real cross-domain
/// federation delivery can take longer than one sync round (this direction
/// is often slower than the other; see the module doc), so the event
/// handler needs repeated sync rounds to have a chance of firing at all,
/// not just a longer wait on a channel nothing is still feeding.
async fn receive_federated_message_with_retry(
    bob: &ManyMatrixClient,
    rx: &mut mpsc::Receiver<String>,
    max_attempts: u32,
    interval: Duration,
) -> Result<String> {
    for attempt in 0..max_attempts {
        bob.sync_once().await?;
        match rx.try_recv() {
            Ok(msg) => return Ok(msg),
            Err(_) => {
                eprintln!("bob: message not yet received after sync attempt {attempt}");
                tokio::time::sleep(interval).await;
            }
        }
    }

    anyhow::bail!("federated message never arrived after {max_attempts} sync attempts")
}

async fn join_room_with_retry(
    client: &ManyMatrixClient,
    room_id_or_alias: &str,
    max_attempts: u32,
    interval: Duration,
) -> Result<String> {
    let mut last_err = None;
    for attempt in 0..max_attempts {
        match client.join_room(room_id_or_alias).await {
            Ok(room_id) => return Ok(room_id),
            Err(error) => {
                eprintln!("join attempt {attempt} failed: {error}");
                last_err = Some(error);
                tokio::time::sleep(interval).await;
            }
        }
    }

    Err(last_err.expect("at least one join attempt runs").into())
}

#[tokio::test]
async fn federated_message_hosted_synapse_to_tuwunel() -> Result<()> {
    init_tracing();
    federated_message(ServerKind::HostedSynapse, ServerKind::HostedTuwunel).await
}

#[tokio::test]
async fn federated_message_hosted_tuwunel_to_synapse() -> Result<()> {
    init_tracing();
    federated_message(ServerKind::HostedTuwunel, ServerKind::HostedSynapse).await
}
