#[cfg(feature = "docker-tests")]
use std::time::Duration;

#[cfg(feature = "docker-tests")]
use anyhow::Context;
use anyhow::Result;

#[cfg(feature = "docker-tests")]
use manymatrix_core::CreateRoomOptions;
use manymatrix_core::ManyMatrixClient;
use test_harness::{ServerKind, TestHomeserver};
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .try_init();
}

async fn finalize_server(server: TestHomeserver, run_result: Result<()>) -> Result<()> {
    if let Err(stop_err) = server.stop().await {
        if run_result.is_ok() {
            return Err(stop_err);
        }

        eprintln!("failed to stop homeserver after test failure: {stop_err:#}");
    }

    run_result
}

#[cfg(feature = "docker-tests")]
async fn sync_pair(
    alice: &ManyMatrixClient,
    bob: &ManyMatrixClient,
    rounds: usize,
    delay_ms: u64,
) -> Result<()> {
    for _ in 0..rounds {
        tokio::try_join!(alice.sync_once(), bob.sync_once())?;
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
    }

    Ok(())
}

/// TEST-04: Two clients complete SAS emoji device verification using the
/// public `ManyMatrixClient` verification API.
#[cfg(feature = "docker-tests")]
async fn sas_verification(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;
    eprintln!("{:?} ready at {}", server.server_kind(), server.base_url());

    let run_result = async {
        let alice_reg = server.register_user("alice_sas", "password1").await?;
        let bob_reg = server.register_user("bob_sas", "password2").await?;

        let alice_store = tempfile::tempdir()?;
        let alice = ManyMatrixClient::new(server.base_url(), alice_store.path()).await?;
        let _alice_session = alice.login(&alice_reg.localpart, "password1").await?;

        let bob_store = tempfile::tempdir()?;
        let bob = ManyMatrixClient::new(server.base_url(), bob_store.path()).await?;
        let _bob_session = bob.login(&bob_reg.localpart, "password2").await?;

        let room_id = alice
            .create_room(CreateRoomOptions {
                name: Some("SAS Verification Room".into()),
                invite: vec![bob_reg.user_id.clone()],
                ..Default::default()
            })
            .await?;
        alice.sync_once().await?;
        bob.sync_once().await?;
        bob.join_room(&room_id).await?;
        alice.sync_once().await?;
        bob.sync_once().await?;

        alice.enable_encryption(&room_id).await?;
        alice.sync_once().await?;
        sync_pair(&alice, &bob, 6, 200).await?;

        let bob_devices = alice
            .inner()
            .encryption()
            .get_user_devices(<&matrix_sdk::ruma::UserId>::try_from(
                bob_reg.user_id.as_str(),
            )?)
            .await?;
        let bob_device = bob_devices
            .devices()
            .next()
            .context("No devices found for Bob")?;
        let bob_device_id = bob_device.device_id().to_string();
        eprintln!("Found Bob's device: {}", bob_device_id);

        let flow_id = alice
            .start_verification(&bob_reg.user_id, &bob_device_id)
            .await?;
        eprintln!("Verification started, flow_id: {}", flow_id);

        let mut accepted = false;
        for attempt in 0..20 {
            sync_pair(&alice, &bob, 1, 200).await?;
            match bob.accept_verification(&alice_reg.user_id, &flow_id).await {
                Ok(()) => {
                    accepted = true;
                    eprintln!("Bob accepted verification on attempt {}", attempt + 1);
                    break;
                }
                Err(error) => eprintln!(
                    "Bob accept verification retry {} failed: {error}",
                    attempt + 1
                ),
            }
        }
        assert!(accepted, "Bob never observed the verification request");

        let mut sas_started = false;
        for attempt in 0..20 {
            sync_pair(&alice, &bob, 1, 200).await?;
            match alice.start_sas(&bob_reg.user_id, &flow_id).await {
                Ok(()) => {
                    sas_started = true;
                    eprintln!("Alice started SAS on attempt {}", attempt + 1);
                    break;
                }
                Err(error) => eprintln!("Alice start SAS retry {} failed: {error}", attempt + 1),
            }
        }
        assert!(sas_started, "Alice never transitioned the request into SAS");

        let mut sas_accepted = false;
        for attempt in 0..20 {
            sync_pair(&alice, &bob, 1, 200).await?;
            match bob.accept_sas(&alice_reg.user_id, &flow_id).await {
                Ok(()) => {
                    sas_accepted = true;
                    eprintln!("Bob accepted SAS on attempt {}", attempt + 1);
                    break;
                }
                Err(error) => eprintln!("Bob accept SAS retry {} failed: {error}", attempt + 1),
            }
        }
        assert!(sas_accepted, "Bob never accepted the SAS verification");

        let mut alice_emojis = None;
        let mut bob_emojis = None;
        for attempt in 0..30 {
            sync_pair(&alice, &bob, 1, 200).await?;

            if alice_emojis.is_none() {
                match alice.get_sas_emojis(&bob_reg.user_id, &flow_id).await {
                    Ok(payload) => {
                        eprintln!("Alice SAS emojis ready on attempt {}", attempt + 1);
                        alice_emojis = Some(payload.emojis);
                    }
                    Err(error) => {
                        eprintln!("Alice get_sas_emojis retry {} failed: {error}", attempt + 1)
                    }
                }
            }

            if bob_emojis.is_none() {
                match bob.get_sas_emojis(&alice_reg.user_id, &flow_id).await {
                    Ok(payload) => {
                        eprintln!("Bob SAS emojis ready on attempt {}", attempt + 1);
                        bob_emojis = Some(payload.emojis);
                    }
                    Err(error) => {
                        eprintln!("Bob get_sas_emojis retry {} failed: {error}", attempt + 1)
                    }
                }
            }

            if alice_emojis.is_some() && bob_emojis.is_some() {
                break;
            }
        }

        let alice_emojis = alice_emojis.context("alice SAS emojis never became available")?;
        let bob_emojis = bob_emojis.context("bob SAS emojis never became available")?;
        assert_eq!(alice_emojis.len(), 7);
        assert_eq!(bob_emojis.len(), 7);
        for (a, b) in alice_emojis.iter().zip(bob_emojis.iter()) {
            assert_eq!(a.symbol, b.symbol, "emoji symbols should match");
        }
        eprintln!("Emojis match!");

        let (alice_confirm, bob_confirm, sync_result) = tokio::join!(
            alice.confirm_sas(&bob_reg.user_id, &flow_id),
            bob.confirm_sas(&alice_reg.user_id, &flow_id),
            sync_pair(&alice, &bob, 10, 200),
        );
        alice_confirm?;
        bob_confirm?;
        sync_result?;
        eprintln!("SAS verification complete");

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

#[cfg(feature = "docker-tests")]
mod sas_verification_tests {
    use super::*;

    #[tokio::test]
    async fn sas_verification_tuwunel_docker() -> Result<()> {
        init_tracing();
        sas_verification(ServerKind::TuwunelDocker).await
    }

    #[tokio::test]
    async fn sas_verification_synapse() -> Result<()> {
        init_tracing();
        sas_verification(ServerKind::Synapse).await
    }
}

/// Bootstrap cross-signing keys.
async fn cross_signing_bootstrap(kind: ServerKind) -> Result<()> {
    let server = TestHomeserver::start(kind).await?;

    let run_result = async {
        let user = server.register_user("cross_sign_user", "password1").await?;

        let store = tempfile::tempdir()?;
        let client = ManyMatrixClient::new(server.base_url(), store.path()).await?;
        let _session = client.login(&user.localpart, "password1").await?;
        client.sync_once().await?;

        client.bootstrap_cross_signing().await?;
        eprintln!("Cross-signing bootstrapped successfully");

        Ok(())
    }
    .await;

    finalize_server(server, run_result).await
}

test_harness::e2e_test!(cross_signing_bootstrap);
