use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::Deserialize;

use crate::envelope::{ErrEnvelope, ErrKind};
use manymatrix_core::{ManyMatrixClient, StoredSession};

thread_local! {
    static CLIENT: RefCell<Option<ManyMatrixClient>> = RefCell::new(None);
}

static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);

pub fn set_client(client: ManyMatrixClient) {
    CLIENT.with(|cell| *cell.borrow_mut() = Some(client));
}

pub fn get_client() -> Result<ManyMatrixClient, ErrEnvelope> {
    CLIENT.with(|cell| {
        cell.borrow().as_ref().cloned().ok_or_else(|| ErrEnvelope {
            kind: ErrKind::StorageError,
            message: "not logged in".into(),
            details: serde_json::json!({}),
        })
    })
}

pub fn clear_client() {
    CLIENT.with(|cell| *cell.borrow_mut() = None);
}

#[derive(Deserialize)]
struct EchoArgs {
    message: String,
}

#[derive(Deserialize)]
struct LoginArgs {
    homeserver_url: String,
    username: String,
    password: String,
    store_name: String,
}

#[derive(Deserialize)]
struct RestoreArgs {
    homeserver_url: String,
    session_json: String,
    store_name: String,
}

fn sdk_err(e: manymatrix_core::Error) -> ErrEnvelope {
    ErrEnvelope {
        kind: ErrKind::MatrixSdkError,
        message: e.to_string(),
        details: serde_json::json!({}),
    }
}

fn serde_err(e: serde_json::Error) -> ErrEnvelope {
    ErrEnvelope {
        kind: ErrKind::SerdeError,
        message: e.to_string(),
        details: serde_json::json!({}),
    }
}

pub async fn dispatch(method: &str, args_json: &str) -> Result<serde_json::Value, ErrEnvelope> {
    match method {
        "dispatcher.echo" => {
            let args: EchoArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            Ok(serde_json::json!({
                "message": args.message,
                "echoed_at_wasm_ts_ms": js_sys::Date::now() as u64,
            }))
        }
        "dispatcher.panic" => {
            panic!("intentional test panic");
        }
        "auth.login" => {
            let args: LoginArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let mm = ManyMatrixClient::new(&args.homeserver_url, &args.store_name)
                .await
                .map_err(sdk_err)?;
            let session = mm
                .login(&args.username, &args.password)
                .await
                .map_err(sdk_err)?;
            let session_json = serde_json::to_string(&session).map_err(serde_err)?;
            let user_id = mm
                .inner()
                .user_id()
                .map(|u| u.to_string())
                .unwrap_or_default();
            let device_id = mm
                .inner()
                .device_id()
                .map(|d| d.to_string())
                .unwrap_or_default();
            set_client(mm);
            tracing::info!("auth.login ok, user={}", user_id);
            Ok(serde_json::json!({
                "session_json": session_json,
                "user_id": user_id,
                "device_id": device_id,
            }))
        }
        "auth.restore" => {
            let args: RestoreArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let session: StoredSession =
                serde_json::from_str(&args.session_json).map_err(serde_err)?;
            let mm = ManyMatrixClient::new(&args.homeserver_url, &args.store_name)
                .await
                .map_err(sdk_err)?;
            mm.restore(&session).await.map_err(sdk_err)?;
            let user_id = mm
                .inner()
                .user_id()
                .map(|u| u.to_string())
                .unwrap_or_default();
            let device_id = mm
                .inner()
                .device_id()
                .map(|d| d.to_string())
                .unwrap_or_default();
            set_client(mm);
            tracing::info!("auth.restore ok, user={}", user_id);
            Ok(serde_json::json!({
                "user_id": user_id,
                "device_id": device_id,
            }))
        }
        "auth.logout" => {
            let client = get_client()?;
            client.logout().await.map_err(sdk_err)?;
            clear_client();
            SYNC_RUNNING.store(false, Ordering::Relaxed);
            tracing::info!("auth.logout ok");
            Ok(serde_json::json!({}))
        }
        "sync.start" => {
            if SYNC_RUNNING.load(Ordering::Relaxed) {
                return Ok(serde_json::json!({"already_running": true}));
            }
            let client = get_client()?;
            SYNC_RUNNING.store(true, Ordering::Relaxed);
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(e) = client.sync_forever().await {
                    tracing::error!("sync loop exited: {}", e);
                }
                SYNC_RUNNING.store(false, Ordering::Relaxed);
            });
            Ok(serde_json::json!({}))
        }
        "sync.once" => {
            let client = get_client()?;
            client.sync_once().await.map_err(sdk_err)?;
            let token = client.sync_token_clone().await;
            Ok(serde_json::json!({"next_batch": token}))
        }
        "sync.status" => {
            let logged_in = CLIENT.with(|cell| cell.borrow().is_some());
            if logged_in {
                let client = get_client()?;
                let token = client.sync_token_clone().await;
                let syncing = SYNC_RUNNING.load(Ordering::Relaxed);
                Ok(serde_json::json!({
                    "logged_in": true,
                    "syncing": syncing,
                    "sync_token": token,
                }))
            } else {
                Ok(serde_json::json!({"logged_in": false}))
            }
        }
        _ => Err(ErrEnvelope {
            kind: ErrKind::SerdeError,
            message: format!("unknown method: {}", method),
            details: serde_json::json!({}),
        }),
    }
}
