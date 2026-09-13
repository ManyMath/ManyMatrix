use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;

use crate::envelope::{ErrEnvelope, ErrKind};
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient, RoomVisibility, StoredSession};

thread_local! {
    static CLIENT: RefCell<Option<ManyMatrixClient>> = const { RefCell::new(None) };
    static EVENT_SINK: RefCell<Option<js_sys::Function>> = const { RefCell::new(None) };
    // Custom event types with a handler on the current client. Like
    // EVENTS_SUBSCRIBED, this resets whenever the client is replaced.
    static CUSTOM_EVENT_TYPES: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
    // Cancel flag of the loop started by the latest `sync.start`; taken (and
    // set) by `sync.stop` and `auth.logout`.
    static SYNC_CANCEL: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
}

static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);
// Bumped by every `sync.start` and `auth.logout`. A loop that finds the
// generation moved on belongs to a previous client (or a stopped run) and
// exits without touching the shared flags or emitting a status.
static SYNC_GENERATION: AtomicU64 = AtomicU64::new(0);
// Event handlers attach to a specific client instance, so a new client
// (login/restore) needs a fresh events.subscribe call.
static EVENTS_SUBSCRIBED: AtomicBool = AtomicBool::new(false);

pub fn set_client(client: ManyMatrixClient) {
    CLIENT.with(|cell| *cell.borrow_mut() = Some(client));
    EVENTS_SUBSCRIBED.store(false, Ordering::Relaxed);
    CUSTOM_EVENT_TYPES.with(|types| types.borrow_mut().clear());
}

pub fn set_event_sink(sink: js_sys::Function) {
    EVENT_SINK.with(|cell| *cell.borrow_mut() = Some(sink));
}

fn emit_event(kind: &str, payload: &impl serde::Serialize) {
    let payload_json = match serde_json::to_string(payload) {
        Ok(json) => json,
        Err(e) => {
            tracing::error!("failed to serialize {} event: {}", kind, e);
            return;
        }
    };
    emit_event_payload_json(kind, &payload_json);
}

fn emit_event_payload_json(kind: &str, payload_json: &str) {
    EVENT_SINK.with(|cell| {
        if let Some(sink) = cell.borrow().as_ref() {
            if let Err(e) = sink.call2(
                &wasm_bindgen::JsValue::NULL,
                &wasm_bindgen::JsValue::from_str(kind),
                &wasm_bindgen::JsValue::from_str(payload_json),
            ) {
                tracing::warn!("event sink call failed for {}: {:?}", kind, e);
            }
        }
    });
}

fn emit_session_update(session_json: String) {
    emit_event_payload_json("session_update", &session_json);
}

fn attach_session_update_sink(client: &ManyMatrixClient) {
    client.set_session_update_callback(emit_session_update);
}

fn sync_status_json(state: &str, ok: bool, error: Option<String>) -> serde_json::Value {
    let mut status = serde_json::json!({
        "state": state,
        "ok": ok,
    });
    if let Some(error) = error {
        status["error"] = serde_json::Value::String(error);
    }
    status
}

/// Same shape as the native bridge's failed sync status: the structured
/// `errorKind`/`errorDetails` fields are what lets the app detect a revoked
/// token without parsing the message text.
fn failed_sync_status_json(error: &manymatrix_core::Error) -> serde_json::Value {
    let mut status = sync_status_json("exited", false, Some(error.to_string()));
    status["errorKind"] =
        serde_json::Value::String(ErrKind::for_core_error(error).as_str().to_owned());
    status["errorDetails"] = error.details();
    status
}

/// Ask the running background loop, if any, to stop. It exits within the
/// core's cancel poll interval instead of finishing its long-poll first.
fn cancel_sync_loop() {
    SYNC_CANCEL.with(|cell| {
        if let Some(cancel) = cell.borrow_mut().take() {
            cancel.store(true, Ordering::Relaxed);
        }
    });
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
    EVENTS_SUBSCRIBED.store(false, Ordering::Relaxed);
    CUSTOM_EVENT_TYPES.with(|types| types.borrow_mut().clear());
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
    device_id: Option<String>,
    store_name: String,
}

#[derive(Deserialize)]
struct RestoreArgs {
    homeserver_url: String,
    session_json: String,
    store_name: String,
}

#[derive(Deserialize)]
struct SyncOnceArgs {
    timeout_ms: Option<u64>,
}

#[derive(Deserialize)]
struct SendCustomEventArgs {
    room_id: String,
    event_type: String,
    content: serde_json::Value,
}

#[derive(Deserialize)]
struct SubscribeCustomEventArgs {
    event_type: String,
}

#[derive(Deserialize)]
struct SendTextArgs {
    room_id: String,
    body: String,
}

#[derive(Deserialize)]
struct SendHtmlArgs {
    room_id: String,
    body: String,
    html: String,
}

#[derive(Deserialize)]
struct EditMessageArgs {
    room_id: String,
    event_id: String,
    new_body: String,
}

#[derive(Deserialize)]
struct ReplyArgs {
    room_id: String,
    event_id: String,
    body: String,
}

#[derive(Deserialize)]
struct ReactionArgs {
    room_id: String,
    event_id: String,
    key: String,
}

#[derive(Deserialize)]
struct RedactArgs {
    room_id: String,
    event_id: String,
    reason: Option<String>,
}

#[derive(Deserialize)]
struct ThreadReplyArgs {
    room_id: String,
    thread_root_event_id: String,
    in_reply_to_event_id: String,
    body: String,
}

#[derive(Deserialize)]
struct GetMessagesArgs {
    room_id: String,
    from_token: Option<String>,
    limit: u32,
}

#[derive(Deserialize)]
struct ThreadIndexArgs {
    limit_per_room: u32,
}

#[derive(Deserialize)]
struct GetThreadMessagesArgs {
    room_id: String,
    thread_root_event_id: String,
    from_token: Option<String>,
    limit: u32,
}

#[derive(Deserialize)]
struct ThreadReadReceiptArgs {
    room_id: String,
    thread_root_event_id: String,
    event_id: String,
}

#[derive(Deserialize)]
struct CreateRoomArgs {
    name: Option<String>,
    topic: Option<String>,
    #[serde(default)]
    invite: Vec<String>,
    #[serde(default)]
    public: bool,
}

#[derive(Deserialize)]
struct JoinRoomArgs {
    room_id_or_alias: String,
}

#[derive(Deserialize)]
struct RoomUserArgs {
    room_id: String,
    user_id: String,
}

#[derive(Deserialize)]
struct CustomEventPowerLevelsArgs {
    room_id: String,
    event_type: String,
    required_power_level: i64,
    #[serde(default)]
    user_power_levels: std::collections::BTreeMap<String, i64>,
}

#[derive(Deserialize)]
struct RoomInvitePowerLevelArgs {
    room_id: String,
    required_power_level: i64,
    #[serde(default)]
    user_power_levels: std::collections::BTreeMap<String, i64>,
}

#[derive(Deserialize)]
struct RoomIdArgs {
    room_id: String,
}

#[derive(Deserialize)]
struct RoomUserReasonArgs {
    room_id: String,
    user_id: String,
    reason: Option<String>,
}

#[derive(Deserialize)]
struct RoomEventArgs {
    room_id: String,
    event_id: String,
}

#[derive(Deserialize)]
struct TypingArgs {
    room_id: String,
    typing: bool,
}

#[derive(Deserialize)]
struct UploadMediaArgs {
    room_id: String,
    filename: String,
    mime_type: String,
    data_base64: String,
}

#[derive(Deserialize)]
struct DownloadMediaArgs {
    mxc_uri: Option<String>,
    media_source: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct RegisterPusherArgs {
    app_id: String,
    push_key: String,
    app_display_name: String,
    device_display_name: String,
    push_url: String,
    lang: String,
}

#[derive(Deserialize)]
struct StartVerificationArgs {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
struct VerificationFlowArgs {
    user_id: String,
    flow_id: String,
}

#[derive(Deserialize)]
struct RestoreKeyBackupArgs {
    recovery_key: String,
}

#[derive(Deserialize)]
struct ThumbnailArgs {
    mxc_uri: String,
    width: u32,
    height: u32,
}

fn sdk_err(e: manymatrix_core::Error) -> ErrEnvelope {
    let details = e.details();
    ErrEnvelope {
        kind: ErrKind::for_core_error(&e),
        message: e.to_string(),
        details,
    }
}

fn serde_err(e: serde_json::Error) -> ErrEnvelope {
    ErrEnvelope {
        kind: ErrKind::SerdeError,
        message: e.to_string(),
        details: serde_json::json!({}),
    }
}

fn base64_err(e: base64::DecodeError) -> ErrEnvelope {
    ErrEnvelope {
        kind: ErrKind::SerdeError,
        message: format!("invalid base64 data: {e}"),
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
            attach_session_update_sink(&mm);
            let session = mm
                .login_with_device_id(&args.username, &args.password, args.device_id.as_deref())
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
            attach_session_update_sink(&mm);
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
        "auth.whoami" => {
            let client = get_client()?;
            let user_id = client.current_user_id();
            Ok(serde_json::json!({"user_id": user_id}))
        }
        "auth.logout" => {
            let client = get_client()?;
            // Stop the background loop first: it holds its own client clone
            // and would keep long-polling with the token being revoked.
            SYNC_GENERATION.fetch_add(1, Ordering::Relaxed);
            cancel_sync_loop();
            SYNC_RUNNING.store(false, Ordering::Relaxed);
            // The core wipes local session state even when the server-side
            // revocation fails, so the client is unusable either way.
            let result = client.logout().await;
            clear_client();
            result.map_err(sdk_err)?;
            tracing::info!("auth.logout ok");
            Ok(serde_json::json!({}))
        }
        "sync.start" => {
            let stopping = SYNC_CANCEL.with(|cell| {
                cell.borrow()
                    .as_ref()
                    .is_none_or(|c| c.load(Ordering::Relaxed))
            });
            if SYNC_RUNNING.load(Ordering::Relaxed) && !stopping {
                return Ok(serde_json::json!({"already_running": true}));
            }
            let client = get_client()?;
            // A loop that is still winding down after `sync.stop` sees the new
            // generation and exits without reporting.
            let generation = SYNC_GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
            let cancel = Arc::new(AtomicBool::new(false));
            SYNC_CANCEL.with(|cell| *cell.borrow_mut() = Some(cancel.clone()));
            SYNC_RUNNING.store(true, Ordering::Relaxed);
            wasm_bindgen_futures::spawn_local(async move {
                let status = match client.sync_until_cancelled(cancel).await {
                    Ok(()) => sync_status_json("exited", true, None),
                    Err(e) => {
                        tracing::error!("sync loop exited: {}", e);
                        failed_sync_status_json(&e)
                    }
                };
                // A logout or a newer `sync.start` owns the flags (and the
                // status report) now.
                if SYNC_GENERATION.load(Ordering::Relaxed) != generation {
                    return;
                }
                SYNC_RUNNING.store(false, Ordering::Relaxed);
                SYNC_CANCEL.with(|cell| cell.borrow_mut().take());
                emit_event("sync_status", &status);
            });
            Ok(serde_json::json!({}))
        }
        "sync.stop" => {
            let was_running = SYNC_RUNNING.load(Ordering::Relaxed);
            cancel_sync_loop();
            Ok(serde_json::json!({"was_running": was_running}))
        }
        "sync.once" => {
            let args: SyncOnceArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            if let Some(timeout_ms) = args.timeout_ms {
                client
                    .sync_once_with_timeout(Duration::from_millis(timeout_ms))
                    .await
                    .map_err(sdk_err)?;
            } else {
                client.sync_once().await.map_err(sdk_err)?;
            }
            let token = client.sync_token_clone().await;
            Ok(serde_json::json!({"next_batch": token}))
        }
        "rooms.create" => {
            let args: CreateRoomArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let options = CreateRoomOptions {
                name: args.name,
                topic: args.topic,
                invite: args.invite,
                visibility: if args.public {
                    RoomVisibility::Public
                } else {
                    RoomVisibility::Private
                },
            };
            let room_id = client.create_room(options).await.map_err(sdk_err)?;
            Ok(serde_json::json!({"room_id": room_id}))
        }
        "rooms.join" => {
            let args: JoinRoomArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let room_id = client
                .join_room(&args.room_id_or_alias)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"room_id": room_id}))
        }
        "rooms.invite" => {
            let args: RoomUserArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .invite(&args.room_id, &args.user_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.set_custom_event_power_levels" => {
            let args: CustomEventPowerLevelsArgs =
                serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .set_custom_event_power_levels(
                    &args.room_id,
                    &args.event_type,
                    args.required_power_level,
                    args.user_power_levels.into_iter().collect(),
                )
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.power_levels" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let snapshot = client
                .room_power_levels(&args.room_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({
                "power_levels_json": serde_json::to_string(&snapshot).map_err(serde_err)?
            }))
        }
        "rooms.set_invite_power_level" => {
            let args: RoomInvitePowerLevelArgs =
                serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .set_room_invite_power_level(
                    &args.room_id,
                    args.required_power_level,
                    args.user_power_levels.into_iter().collect(),
                )
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.leave" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client.leave_room(&args.room_id).await.map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.kick" => {
            let args: RoomUserReasonArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .kick(&args.room_id, &args.user_id, args.reason.as_deref())
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.ban" => {
            let args: RoomUserReasonArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .ban(&args.room_id, &args.user_id, args.reason.as_deref())
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.name" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let name = client.room_name(&args.room_id).map_err(sdk_err)?;
            Ok(serde_json::json!({"name": name}))
        }
        "rooms.topic" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let topic = client.room_topic(&args.room_id).map_err(sdk_err)?;
            Ok(serde_json::json!({"topic": topic}))
        }
        "rooms.avatar_url" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let avatar_url = client.room_avatar_url(&args.room_id).map_err(sdk_err)?;
            Ok(serde_json::json!({"avatar_url": avatar_url}))
        }
        "rooms.members" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let members = client.room_members(&args.room_id).await.map_err(sdk_err)?;
            let members_json = serde_json::to_string(&members).map_err(serde_err)?;
            Ok(serde_json::json!({"members_json": members_json}))
        }
        "rooms.read_receipt" => {
            let args: RoomEventArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .send_read_receipt(&args.room_id, &args.event_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "rooms.typing" => {
            let args: TypingArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .send_typing(&args.room_id, args.typing)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "server.capabilities" => {
            let client = get_client()?;
            let capabilities = client.server_capabilities().await.map_err(sdk_err)?;
            let capabilities_json = serde_json::to_string(&capabilities).map_err(serde_err)?;
            Ok(serde_json::json!({"capabilities_json": capabilities_json}))
        }
        "rooms.list" => {
            let client = get_client()?;
            let rooms = client.joined_rooms().await;
            let rooms_json = serde_json::to_string(&rooms).map_err(serde_err)?;
            Ok(serde_json::json!({"rooms_json": rooms_json}))
        }
        "rooms.invited" => {
            let client = get_client()?;
            let invites = client.invited_rooms().await;
            let invites_json = serde_json::to_string(&invites).map_err(serde_err)?;
            Ok(serde_json::json!({"invites_json": invites_json}))
        }
        "rooms.details" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let details = client.room_details(&args.room_id).map_err(sdk_err)?;
            let details_json = serde_json::to_string(&details).map_err(serde_err)?;
            Ok(serde_json::json!({"details_json": details_json}))
        }
        "messages.get" => {
            let args: GetMessagesArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let paginated = client
                .get_messages(&args.room_id, args.from_token.as_deref(), args.limit)
                .await
                .map_err(sdk_err)?;
            let paginated_json = serde_json::to_string(&paginated).map_err(serde_err)?;
            Ok(serde_json::json!({"paginated_json": paginated_json}))
        }
        "threads.index" => {
            let args: ThreadIndexArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let threads = client
                .thread_index(args.limit_per_room)
                .await
                .map_err(sdk_err)?;
            let threads_json = serde_json::to_string(&threads).map_err(serde_err)?;
            Ok(serde_json::json!({"threads_json": threads_json}))
        }
        "threads.messages" => {
            let args: GetThreadMessagesArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let paginated = client
                .get_thread_messages(
                    &args.room_id,
                    &args.thread_root_event_id,
                    args.from_token.as_deref(),
                    args.limit,
                )
                .await
                .map_err(sdk_err)?;
            let paginated_json = serde_json::to_string(&paginated).map_err(serde_err)?;
            Ok(serde_json::json!({"paginated_json": paginated_json}))
        }
        "threads.read_receipt" => {
            let args: ThreadReadReceiptArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .send_thread_read_receipt(&args.room_id, &args.thread_root_event_id, &args.event_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "messages.send_custom_event" => {
            let args: SendCustomEventArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_custom_event(&args.room_id, &args.event_type, args.content)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.send_text" => {
            let args: SendTextArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_text(&args.room_id, &args.body)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.send_html" => {
            let args: SendHtmlArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_html(&args.room_id, &args.body, &args.html)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.send_notice" => {
            let args: SendTextArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_notice(&args.room_id, &args.body)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.send_emote" => {
            let args: SendTextArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_emote(&args.room_id, &args.body)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.edit" => {
            let args: EditMessageArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .edit_message(&args.room_id, &args.event_id, &args.new_body)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "messages.reply" => {
            let args: ReplyArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .reply_to(&args.room_id, &args.event_id, &args.body)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.react" => {
            let args: ReactionArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_reaction(&args.room_id, &args.event_id, &args.key)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "messages.redact" => {
            let args: RedactArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .redact(&args.room_id, &args.event_id, args.reason.as_deref())
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "messages.thread_reply" => {
            let args: ThreadReplyArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let event_id = client
                .send_thread_reply(
                    &args.room_id,
                    &args.thread_root_event_id,
                    &args.in_reply_to_event_id,
                    &args.body,
                )
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "media.upload" => {
            use base64::Engine as _;
            let args: UploadMediaArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let data = base64::engine::general_purpose::STANDARD
                .decode(&args.data_base64)
                .map_err(base64_err)?;
            let client = get_client()?;
            let event_id = client
                .upload_media(&args.room_id, &args.filename, &args.mime_type, data)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"event_id": event_id}))
        }
        "media.download" => {
            use base64::Engine as _;
            let args: DownloadMediaArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let data = if let Some(source) = args.media_source.as_ref() {
                client
                    .download_media_source(source)
                    .await
                    .map_err(sdk_err)?
            } else if let Some(mxc_uri) = args.mxc_uri.as_deref() {
                client.download_media(mxc_uri).await.map_err(sdk_err)?
            } else {
                return Err(ErrEnvelope {
                    kind: ErrKind::SerdeError,
                    message: "media.download requires media_source or mxc_uri".to_owned(),
                    details: serde_json::json!({}),
                });
            };
            let data_base64 = base64::engine::general_purpose::STANDARD.encode(data);
            Ok(serde_json::json!({"data_base64": data_base64}))
        }
        "media.thumbnail" => {
            use base64::Engine as _;
            let args: ThumbnailArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let data = client
                .get_thumbnail(&args.mxc_uri, args.width, args.height)
                .await
                .map_err(sdk_err)?;
            let data_base64 = base64::engine::general_purpose::STANDARD.encode(data);
            Ok(serde_json::json!({"data_base64": data_base64}))
        }
        "pushers.register" => {
            let args: RegisterPusherArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .register_pusher(
                    &args.app_id,
                    &args.push_key,
                    &args.app_display_name,
                    &args.device_display_name,
                    &args.push_url,
                    &args.lang,
                )
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.is_encrypted" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let encrypted = client
                .is_room_encrypted(&args.room_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"encrypted": encrypted}))
        }
        "e2ee.enable" => {
            let args: RoomIdArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .enable_encryption(&args.room_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.start_verification" => {
            let args: StartVerificationArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let flow_id = client
                .start_verification(&args.user_id, &args.device_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({"flow_id": flow_id}))
        }
        "e2ee.accept_verification" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .accept_verification(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.start_sas" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .start_sas(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.accept_sas" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .accept_sas(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.sas_emojis" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            let emojis = client
                .get_sas_emojis(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            let emojis_json = serde_json::to_string(&emojis).map_err(serde_err)?;
            Ok(serde_json::json!({"emojis_json": emojis_json}))
        }
        "e2ee.confirm_sas" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .confirm_sas(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.cancel_verification" => {
            let args: VerificationFlowArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .cancel_verification(&args.user_id, &args.flow_id)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.bootstrap_cross_signing" => {
            let client = get_client()?;
            client.bootstrap_cross_signing().await.map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.setup_key_backup" => {
            let client = get_client()?;
            client.setup_key_backup().await.map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.restore_key_backup" => {
            let args: RestoreKeyBackupArgs = serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            client
                .restore_key_backup(&args.recovery_key)
                .await
                .map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "e2ee.enable_recovery" => {
            let client = get_client()?;
            let recovery_key = client.enable_recovery().await.map_err(sdk_err)?;
            Ok(serde_json::json!({"recovery_key": recovery_key}))
        }
        "e2ee.wait_for_backup_upload" => {
            let client = get_client()?;
            client.wait_for_backup_upload().await.map_err(sdk_err)?;
            Ok(serde_json::json!({}))
        }
        "events.subscribe" => {
            let client = get_client()?;
            if EVENTS_SUBSCRIBED.swap(true, Ordering::Relaxed) {
                return Ok(serde_json::json!({"already_subscribed": true}));
            }
            client.on_message(|msg| emit_event("message", &msg));
            client.on_reaction(|reaction| emit_event("reaction", &reaction));
            client.on_receipt(|receipt| emit_event("receipt", &receipt));
            tracing::info!("events.subscribe ok");
            Ok(serde_json::json!({}))
        }
        "events.subscribe_custom" => {
            let args: SubscribeCustomEventArgs =
                serde_json::from_str(args_json).map_err(serde_err)?;
            let client = get_client()?;
            // matrix-sdk handlers cannot be removed through the core API, so
            // register each event type once per client and let the bridge fan
            // the `custom_event` stream out to its own listeners.
            let newly_added =
                CUSTOM_EVENT_TYPES.with(|types| types.borrow_mut().insert(args.event_type.clone()));
            if !newly_added {
                return Ok(serde_json::json!({"already_subscribed": true}));
            }
            client.on_custom_event(&args.event_type, |event| emit_event("custom_event", &event));
            tracing::info!("events.subscribe_custom ok for {}", args.event_type);
            Ok(serde_json::json!({}))
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

#[cfg(test)]
mod tests {
    use super::{failed_sync_status_json, sdk_err, sync_status_json};
    use crate::envelope::ErrKind;

    #[test]
    fn sync_status_json_omits_error_for_running_state() {
        let status = sync_status_json("running", true, None);

        assert_eq!(status["state"], "running");
        assert_eq!(status["ok"], true);
        assert!(status.get("error").is_none());
    }

    #[test]
    fn sync_status_json_includes_error_for_failed_exit() {
        let status = sync_status_json("exited", false, Some("network dropped".to_owned()));

        assert_eq!(status["state"], "exited");
        assert_eq!(status["ok"], false);
        assert_eq!(status["error"], "network dropped");
    }

    #[test]
    fn sdk_err_uses_core_error_details() {
        let envelope = sdk_err(manymatrix_core::Error::Other("not ready".to_string()));

        assert!(envelope.details.as_object().unwrap().is_empty());
        assert_eq!(envelope.message, "not ready");
        assert_eq!(envelope.kind, ErrKind::MatrixSdkError);
    }

    #[test]
    fn sdk_err_classifies_errors_like_the_native_bridge() {
        let parse = sdk_err(manymatrix_core::Error::IdParse("bad room".to_owned()));
        assert_eq!(parse.kind, ErrKind::SerdeError);

        let io = sdk_err(manymatrix_core::Error::Io(std::io::Error::other("disk")));
        assert_eq!(io.kind, ErrKind::StorageError);
    }

    #[test]
    fn failed_sync_status_json_carries_structured_fields() {
        let status = failed_sync_status_json(&manymatrix_core::Error::MediaTooLarge {
            actual_bytes: 2,
            max_bytes: 1,
        });

        assert_eq!(status["state"], "exited");
        assert_eq!(status["ok"], false);
        assert_eq!(status["errorKind"], "MatrixSdkError");
        assert_eq!(status["errorDetails"]["reason"], "media_too_large");
    }
}
