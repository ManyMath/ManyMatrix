use futures_util::{future::join_all, stream, StreamExt};
use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read};
#[cfg(any(target_family = "wasm", test))]
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex as StdMutex,
};
use std::time::Duration;
#[cfg(not(target_family = "wasm"))]
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

use matrix_sdk::attachment::AttachmentConfig;
use matrix_sdk::config::SyncSettings;
use matrix_sdk::encryption::{BackupDownloadStrategy, EncryptionSettings};
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::room::{IncludeRelations, ListThreadsOptions, MessagesOptions, RelationsOptions};
use matrix_sdk::ruma::api::client::error::ErrorKind;
use matrix_sdk::ruma::api::client::filter::FilterDefinition;
use matrix_sdk::ruma::api::client::membership::joined_members::v3::Request as JoinedMembersRequest;
use matrix_sdk::ruma::api::client::message::send_message_event::v3::Request as SendMessageEventRequest;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::api::client::room::create_room::v3::{
    Request as CreateRoomRequest, RoomPreset,
};
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::api::client::state::get_state_event_for_key::v3::Request as GetStateEventRequest;
use matrix_sdk::ruma::api::client::sync::sync_events::v3::{
    Filter as SyncFilter, Request as ThreadUnreadSyncRequest,
};
use matrix_sdk::ruma::api::{FeatureFlag, MatrixVersion, SupportedVersions};
use matrix_sdk::ruma::events::reaction::ReactionEventContent;
use matrix_sdk::ruma::events::receipt::{ReceiptEventContent, ReceiptThread};
use matrix_sdk::ruma::events::relation::{Annotation, Thread};
use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
use matrix_sdk::ruma::events::room::message::{
    AddMentions, AudioInfo, AudioMessageEventContent, FileInfo, FileMessageEventContent,
    ForwardThread, ImageMessageEventContent, MessageType, Relation, ReplyMetadata,
    ReplyWithinThread, RoomMessageEventContent, RoomMessageEventContentWithoutRelation,
    SyncRoomMessageEvent, VideoInfo, VideoMessageEventContent,
};
use matrix_sdk::ruma::events::room::power_levels::RoomPowerLevelsEventContent;
use matrix_sdk::ruma::events::room::redaction::SyncRoomRedactionEvent;
use matrix_sdk::ruma::events::room::{ImageInfo, MediaSource};
use matrix_sdk::ruma::events::{
    AnyMessageLikeEvent, AnyMessageLikeEventContent, AnySyncMessageLikeEvent, AnyTimelineEvent,
    MessageLikeEvent, MessageLikeEventContent, OriginalSyncMessageLikeEvent, StateEventType,
    SyncEphemeralRoomEvent, TimelineEventType,
};
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::ruma::{
    api::Direction, DeviceId, EventId, MxcUri, OwnedRoomId, OwnedTransactionId, RoomId,
    RoomOrAliasId, TransactionId, UInt, UserId,
};
use matrix_sdk::{Client, EncryptionState, Room, RoomState, SendOutsideWasm, SyncOutsideWasm};
use tracing::info;

use crate::session::StoredSession;
use crate::types::{
    CreateRoomOptions, CustomEvent, LastMessage, MessageEvent, PaginatedMessages,
    PaginatedThreadMessages, ReactionEvent, ReceiptEvent, RoomDetails, RoomInvite, RoomSummary,
    RoomVisibility, SasEmoji, SasEmojis, ServerCapabilities, ThreadSummary,
};
use crate::Error;

const BACKGROUND_SYNC_TIMEOUT: Duration = Duration::from_secs(30);
const BACKGROUND_SYNC_CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(50);
const SYNC_ONCE_DEADLINE_GRACE: Duration = Duration::from_secs(5);
const MAX_MEDIA_DOWNLOAD_BYTES: usize = 25 * 1024 * 1024;
const THREAD_INDEX_CONCURRENCY: usize = 8;

#[cfg(not(target_family = "wasm"))]
#[derive(Clone, Debug, Default)]
pub struct ClientOptions {
    pub custom_root_certificate_paths: Vec<PathBuf>,
}

#[cfg(not(target_family = "wasm"))]
impl ClientOptions {
    pub fn with_custom_root_certificate_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.custom_root_certificate_paths.push(path.into());
        self
    }
}

fn canonical_homeserver_url(homeserver_url: &str) -> Result<String, Error> {
    let mut url = url::Url::parse(homeserver_url)
        .map_err(|error| Error::Other(format!("invalid homeserver URL: {error}")))?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(Error::Other(
            "homeserver URL cannot contain credentials, a query, or a fragment".into(),
        ));
    }
    if !matches!(url.scheme(), "http" | "https") {
        return Err(Error::Other(
            "homeserver must use an HTTP or HTTPS URL".into(),
        ));
    }
    url.host_str()
        .ok_or_else(|| Error::Other("homeserver URL must include a host".into()))?;

    let mut path = url.path().to_owned();
    while path.len() > 1 && path.ends_with('/') {
        path.pop();
    }
    url.set_path(if path == "/" { "" } else { &path });
    let mut canonical = url.to_string();
    if canonical.ends_with('/') && url.path() == "/" {
        canonical.pop();
    }
    Ok(canonical)
}

#[cfg(any(target_family = "wasm", test))]
fn validate_homeserver_security(homeserver_url: &str) -> Result<(), Error> {
    let canonical = canonical_homeserver_url(homeserver_url)?;
    let url = url::Url::parse(&canonical)
        .map_err(|error| Error::Other(format!("invalid homeserver URL: {error}")))?;
    if url.scheme() == "https" {
        return Ok(());
    }
    let host = url
        .host_str()
        .ok_or_else(|| Error::Other("homeserver URL must include a host".into()))?;
    let ip_host = host.trim_matches(['[', ']']);
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host.to_ascii_lowercase().ends_with(".localhost")
        || ip_host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback());
    if url.scheme() == "http" && loopback {
        return Ok(());
    }
    Err(Error::Other(
        "homeserver must use HTTPS; HTTP is allowed only for loopback development".into(),
    ))
}

#[cfg(not(target_family = "wasm"))]
use std::path::Path;

#[cfg(not(target_family = "wasm"))]
fn custom_root_certificates_from_paths(
    paths: &[PathBuf],
) -> Result<Vec<matrix_sdk::reqwest::Certificate>, Error> {
    let mut certificates = Vec::new();
    for path in paths {
        if path.as_os_str().is_empty() {
            return Err(Error::Other(
                "custom root certificate path cannot be empty".to_owned(),
            ));
        }
        let bytes = std::fs::read(path).map_err(|error| {
            Error::Other(format!(
                "could not read custom root certificate '{}': {error}",
                path.display()
            ))
        })?;
        if bytes.is_empty() {
            return Err(Error::Other(format!(
                "custom root certificate file is empty: {}",
                path.display()
            )));
        }
        let mut parsed =
            matrix_sdk::reqwest::Certificate::from_pem_bundle(&bytes).map_err(|error| {
                Error::Other(format!(
                    "could not parse custom root certificate PEM bundle '{}': {error}",
                    path.display()
                ))
            })?;
        if parsed.is_empty() {
            return Err(Error::Other(format!(
                "custom root certificate PEM bundle did not contain certificates: {}",
                path.display()
            )));
        }
        certificates.append(&mut parsed);
    }
    Ok(certificates)
}

async fn wait_for_background_sync_cancelled(cancelled: &AtomicBool) {
    while !cancelled.load(Ordering::SeqCst) {
        // tokio's timer needs a tokio runtime, which the browser build lacks.
        #[cfg(not(target_family = "wasm"))]
        tokio::time::sleep(BACKGROUND_SYNC_CANCEL_POLL_INTERVAL).await;
        #[cfg(target_family = "wasm")]
        gloo_timers::future::sleep(BACKGROUND_SYNC_CANCEL_POLL_INTERVAL).await;
    }
}

fn room_details_from_room(room: &Room) -> RoomDetails {
    RoomDetails {
        room_id: room.room_id().to_string(),
        canonical_alias: room.canonical_alias().map(|alias| alias.to_string()),
        alt_aliases: room
            .alt_aliases()
            .into_iter()
            .map(|alias| alias.to_string())
            .collect(),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RoomMessageSendMode {
    UseSdk,
    ProbeServer,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ResolvedRoomMessageSendMode {
    UseSdk,
    DirectPlaintext,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RoomEncryptionEventPresence {
    Present,
    Missing,
}

fn send_mode_after_encryption_probe(
    presence: RoomEncryptionEventPresence,
) -> Option<ResolvedRoomMessageSendMode> {
    match presence {
        RoomEncryptionEventPresence::Missing => Some(ResolvedRoomMessageSendMode::DirectPlaintext),
        RoomEncryptionEventPresence::Present => None,
    }
}

fn can_publish_plain_attachment(
    local_state: &EncryptionState,
    second_probe: RoomEncryptionEventPresence,
) -> bool {
    !local_state.is_encrypted() && second_probe == RoomEncryptionEventPresence::Missing
}

fn room_message_send_mode(encryption_state: &EncryptionState) -> RoomMessageSendMode {
    if encryption_state.is_unknown() {
        RoomMessageSendMode::ProbeServer
    } else {
        RoomMessageSendMode::UseSdk
    }
}

fn attachment_send_mode(encryption_state: &EncryptionState) -> RoomMessageSendMode {
    if encryption_state.is_encrypted() {
        RoomMessageSendMode::UseSdk
    } else {
        RoomMessageSendMode::ProbeServer
    }
}

fn sync_once_deadline(timeout: Duration) -> Duration {
    timeout.saturating_add(SYNC_ONCE_DEADLINE_GRACE)
}

#[cfg(not(target_family = "wasm"))]
async fn sync_once_with_deadline<F, T>(future: F, timeout: Duration) -> Result<T, Error>
where
    F: std::future::Future<Output = Result<T, matrix_sdk::Error>>,
{
    let deadline = sync_once_deadline(timeout);
    tokio::time::timeout(deadline, future)
        .await
        .map_err(|_| {
            Error::Other(format!(
                "sync_once timed out after {}ms",
                deadline.as_millis()
            ))
        })?
        .map_err(Error::from)
}

#[cfg(target_family = "wasm")]
async fn sync_once_with_deadline<F, T>(future: F, timeout: Duration) -> Result<T, Error>
where
    F: std::future::Future<Output = Result<T, matrix_sdk::Error>>,
{
    use futures_util::future::{select, Either};

    let deadline = sync_once_deadline(timeout);
    let deadline_ms = u32::try_from(deadline.as_millis()).unwrap_or(u32::MAX);
    let future = Box::pin(future);
    let timer = Box::pin(gloo_timers::future::TimeoutFuture::new(deadline_ms));
    match select(future, timer).await {
        Either::Left((result, _)) => result.map_err(Error::from),
        Either::Right(((), _)) => Err(Error::Other(format!(
            "sync_once timed out after {}ms",
            deadline.as_millis()
        ))),
    }
}

fn plaintext_message_request<T>(
    room_id: OwnedRoomId,
    transaction_id: OwnedTransactionId,
    content: &T,
) -> Result<SendMessageEventRequest, Error>
where
    T: MessageLikeEventContent,
{
    Ok(SendMessageEventRequest::new(
        room_id,
        transaction_id,
        content,
    )?)
}

fn plaintext_raw_message_request(
    room_id: OwnedRoomId,
    transaction_id: OwnedTransactionId,
    event_type: &str,
    content: &serde_json::Value,
) -> Result<SendMessageEventRequest, Error> {
    let body: Raw<AnyMessageLikeEventContent> = Raw::new(content)?.cast_unchecked();
    Ok(SendMessageEventRequest::new_raw(
        room_id,
        transaction_id,
        event_type.to_owned().into(),
        body,
    ))
}

fn plain_attachment_content(
    filename: &str,
    mime: &mime::Mime,
    content_uri: matrix_sdk::ruma::OwnedMxcUri,
    data_len: usize,
) -> RoomMessageEventContent {
    let source = MediaSource::Plain(content_uri);
    let data_len = u64::try_from(data_len).unwrap_or(u64::MAX);
    let size = Some(UInt::new(data_len).unwrap_or(UInt::MAX));
    let mimetype = Some(mime.as_ref().to_owned());
    let message_type = match mime.type_() {
        mime::IMAGE => {
            let mut info = ImageInfo::new();
            info.mimetype = mimetype;
            info.size = size;
            MessageType::Image(
                ImageMessageEventContent::new(filename.to_owned(), source).info(Box::new(info)),
            )
        }
        mime::AUDIO => {
            let mut info = AudioInfo::new();
            info.mimetype = mimetype;
            info.size = size;
            MessageType::Audio(
                AudioMessageEventContent::new(filename.to_owned(), source).info(Box::new(info)),
            )
        }
        mime::VIDEO => {
            let mut info = VideoInfo::new();
            info.mimetype = mimetype;
            info.size = size;
            MessageType::Video(
                VideoMessageEventContent::new(filename.to_owned(), source).info(Box::new(info)),
            )
        }
        _ => {
            let mut info = FileInfo::new();
            info.mimetype = mimetype;
            info.size = size;
            MessageType::File(
                FileMessageEventContent::new(filename.to_owned(), source).info(Box::new(info)),
            )
        }
    };
    RoomMessageEventContent::new(message_type)
}

#[derive(Clone, Debug)]
struct LastMessageCandidate {
    event_id: Option<String>,
    message: LastMessage,
}

#[cfg(not(target_family = "wasm"))]
fn current_timestamp_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(target_family = "wasm")]
fn current_timestamp_millis() -> u64 {
    let timestamp = js_sys::Date::now();
    if timestamp.is_finite() && timestamp > 0.0 {
        timestamp.min(u64::MAX as f64) as u64
    } else {
        0
    }
}

fn outbound_last_message_candidate(
    event_id: String,
    sender: String,
    content: &RoomMessageEventContent,
    timestamp: u64,
) -> Option<LastMessageCandidate> {
    let event = serde_json::json!({
        "type": "m.room.message",
        "content": serde_json::to_value(content).ok()?,
    });
    let displayed = room_message_content_for_display(&event)?;
    Some(LastMessageCandidate {
        event_id: Some(event_id),
        message: LastMessage {
            sender,
            body: displayed["body"].as_str()?.to_owned(),
            timestamp,
        },
    })
}

fn merge_last_message_candidates(
    synced: Option<&LastMessageCandidate>,
    optimistic: Option<&LastMessageCandidate>,
) -> (Option<LastMessage>, bool) {
    match (synced, optimistic) {
        (Some(synced), Some(optimistic)) => {
            let same_event = synced.event_id.is_some() && synced.event_id == optimistic.event_id;
            if same_event || synced.message.timestamp >= optimistic.message.timestamp {
                (Some(synced.message.clone()), true)
            } else {
                (Some(optimistic.message.clone()), false)
            }
        }
        (Some(synced), None) => (Some(synced.message.clone()), false),
        (None, Some(optimistic)) => (Some(optimistic.message.clone()), false),
        (None, None) => (None, false),
    }
}

/// Callback invoked with the serialized session whenever tokens change.
type SessionUpdateCallback = Arc<StdMutex<Option<Box<dyn Fn(String) + Send + Sync>>>>;

/// High-level Matrix client wrapping [`matrix_sdk::Client`].
#[derive(Clone)]
pub struct ManyMatrixClient {
    client: Client,
    homeserver: String,
    store_path: PathBuf,
    /// The `next_batch` of the last completed sync round, for reporting only.
    /// The `since` token of each round comes from the SDK's state store, which
    /// is updated atomically with the processed response.
    sync_token: Arc<Mutex<Option<String>>>,
    /// Held for the whole of a sync round. Two concurrent rounds would
    /// long-poll from the same `since` token, receive the same batch, and fire
    /// every event handler twice.
    sync_guard: Arc<Mutex<()>>,
    latest_session_json: Arc<StdMutex<Option<String>>>,
    session_update_callback: SessionUpdateCallback,
    /// Set by `logout()`: matrix-sdk keeps the (now revoked) tokens in
    /// memory after the logout request, so this is what makes
    /// `logged_in()` and `current_session_json()` stop advertising them.
    session_revoked: Arc<AtomicBool>,
    /// Whether `sync_forever`'s message-logging event handler has been
    /// attached. matrix-sdk keeps handlers for the client's lifetime, so
    /// attaching one per call logged every message once per restart.
    sync_logging_attached: Arc<AtomicBool>,
    optimistic_last_messages: Arc<StdMutex<HashMap<String, LastMessageCandidate>>>,
    thread_unread_cache: Arc<Mutex<ThreadUnreadCache>>,
}

#[derive(Debug, Default)]
struct ThreadUnreadCache {
    supported: Option<bool>,
}

impl ManyMatrixClient {
    /// Login with username and password.
    pub async fn login(&self, username: &str, password: &str) -> Result<StoredSession, Error> {
        self.login_with_device_id(username, password, None).await
    }

    /// Login while reusing an existing Matrix device and its crypto store.
    pub async fn login_with_device_id(
        &self,
        username: &str,
        password: &str,
        device_id: Option<&str>,
    ) -> Result<StoredSession, Error> {
        let mut login = self
            .client
            .matrix_auth()
            .login_username(username, password)
            .initial_device_display_name("matrix-rust-client")
            .request_refresh_token();
        if let Some(device_id) = device_id {
            login = login.device_id(device_id);
        }
        login.send().await?;
        self.session_revoked.store(false, Ordering::SeqCst);

        let session = self
            .client
            .matrix_auth()
            .session()
            .ok_or_else(|| Error::Other("no session after login".into()))?;

        let stored = StoredSession {
            homeserver: self.homeserver.clone(),
            session,
        };
        self.remember_session_json(&stored)?;
        Ok(stored)
    }

    /// Restore a previously saved session.
    pub async fn restore(&self, session: &StoredSession) -> Result<(), Error> {
        let session_homeserver = canonical_homeserver_url(&session.homeserver)?;
        if session_homeserver != self.homeserver {
            return Err(Error::Other(
                "the saved Matrix session belongs to a different homeserver".into(),
            ));
        }
        let normalized = StoredSession {
            homeserver: self.homeserver.clone(),
            session: session.session.clone(),
        };
        self.client
            .restore_session(normalized.session.clone())
            .await?;
        self.session_revoked.store(false, Ordering::SeqCst);
        self.remember_session_json(&normalized)?;
        Ok(())
    }

    fn remember_session_json(&self, session: &StoredSession) -> Result<(), Error> {
        let json = serde_json::to_string(session)?;
        *self
            .latest_session_json
            .lock()
            .expect("session mutex poisoned") = Some(json);
        Ok(())
    }

    fn publish_session_json(
        latest_session_json: &Arc<StdMutex<Option<String>>>,
        session_update_callback: &SessionUpdateCallback,
        session: &StoredSession,
    ) -> Result<(), Error> {
        let json = serde_json::to_string(session)?;
        *latest_session_json.lock().expect("session mutex poisoned") = Some(json.clone());
        if let Some(callback) = &*session_update_callback
            .lock()
            .expect("session callback mutex poisoned")
        {
            callback(json);
        }
        Ok(())
    }

    /// JSON-serialize the current Matrix session in the persisted
    /// [`StoredSession`] shape.
    pub fn current_session_json(&self) -> Result<Option<String>, Error> {
        if self.session_revoked.load(Ordering::SeqCst) {
            return Ok(None);
        }
        if let Some(session) = self.client.matrix_auth().session() {
            let stored = StoredSession {
                homeserver: self.homeserver.clone(),
                session,
            };
            self.remember_session_json(&stored)?;
        }
        Ok(self
            .latest_session_json
            .lock()
            .expect("session mutex poisoned")
            .clone())
    }

    /// Registers a synchronous callback for Matrix SDK session token updates.
    ///
    /// The SDK invokes this after successful access/refresh-token rotation.
    /// Consumers should persist the JSON immediately so a later restore does
    /// not use stale refresh credentials.
    pub fn set_session_update_callback<F>(&self, callback: F)
    where
        F: Fn(String) + Send + Sync + 'static,
    {
        *self
            .session_update_callback
            .lock()
            .expect("session callback mutex poisoned") = Some(Box::new(callback));
    }

    /// Log out of the homeserver and remove local state.
    pub async fn logout(&self) -> Result<(), Error> {
        // 1. Server-side: invalidate token (do this first)
        let server_result = self.client.matrix_auth().logout().await;

        // 2. Drop process-local room previews even when remote revocation failed.
        self.optimistic_last_messages
            .lock()
            .expect("optimistic message mutex poisoned")
            .clear();
        *self.thread_unread_cache.lock().await = ThreadUnreadCache::default();

        // 3. Stop advertising the revoked tokens. matrix-sdk keeps them in
        // memory after the logout request, so without this a caller that
        // persists `current_session_json()` on teardown would save a dead
        // session and fail with M_UNKNOWN_TOKEN on the next restore.
        self.session_revoked.store(true, Ordering::SeqCst);
        *self
            .latest_session_json
            .lock()
            .expect("session mutex poisoned") = None;

        // 4. Delete entire store directory (crypto keys + state).
        // On wasm the store is IndexedDB, not a directory, this is a no-op there.
        #[cfg(not(target_family = "wasm"))]
        if let Err(error) = std::fs::remove_dir_all(&self.store_path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                // The SQLite pool is still open at this point, which on
                // Windows is enough for the unlink to fail; the keys then
                // survive until the store directory is removed by hand.
                tracing::warn!(
                    "could not remove the local store at {}: {error}",
                    self.store_path.display()
                );
            }
        }

        // If server-side failed, return the error after local cleanup
        server_result?;
        Ok(())
    }

    /// Run the sync loop, printing incoming messages to the log.
    /// Runs until an error occurs.
    pub async fn sync_forever(&self) -> Result<(), Error> {
        self.attach_sync_logging();
        info!("starting sync...");
        self.client.sync(SyncSettings::default()).await?;
        Ok(())
    }

    /// Log incoming room messages. Attached at most once per client.
    fn attach_sync_logging(&self) {
        if self.sync_logging_attached.swap(true, Ordering::SeqCst) {
            return;
        }
        self.client
            .add_event_handler(|ev: SyncRoomMessageEvent, room: Room| async move {
                if let SyncRoomMessageEvent::Original(msg) = ev {
                    let room_name = room
                        .display_name()
                        .await
                        .ok()
                        .map(|n| n.to_string())
                        .unwrap_or_else(|| room.room_id().to_string());
                    info!("[{}] {}: {}", room_name, msg.sender, msg.content.body());
                }
            });
    }

    /// Run the sync loop until `cancelled` becomes true.
    ///
    /// Cancellation interrupts the in-flight long-poll within
    /// `BACKGROUND_SYNC_CANCEL_POLL_INTERVAL`, so the FFI bridge can stop the
    /// background sync thread before Dart callback trampolines are closed and
    /// the web bridge can stop promptly on logout. A round interrupted after
    /// the SDK stored its response is not replayed, because each round starts
    /// from the SDK's stored token; any handlers for that batch that had not
    /// run yet are skipped.
    pub async fn sync_until_cancelled(&self, cancelled: Arc<AtomicBool>) -> Result<(), Error> {
        use futures_util::future::{select, Either};

        info!("starting low-latency sync...");
        while !cancelled.load(Ordering::SeqCst) {
            let round = std::pin::pin!(self.sync_once_with_timeout(BACKGROUND_SYNC_TIMEOUT));
            let stop = std::pin::pin!(wait_for_background_sync_cancelled(&cancelled));
            match select(round, stop).await {
                Either::Left((result, _)) => result?,
                Either::Right(((), _)) => break,
            }
        }
        Ok(())
    }

    /// Single sync round, continuing from the last processed response.
    ///
    /// Rounds on one client are serialized: a call made while another round
    /// is in flight (for example the background sync loop's long-poll) waits
    /// for it to finish, then runs its own round from the advanced token.
    pub async fn sync_once(&self) -> Result<(), Error> {
        self.sync_once_with_timeout_inner(None).await
    }

    /// Single sync round with an explicit long-poll timeout.
    pub async fn sync_once_with_timeout(&self, timeout: Duration) -> Result<(), Error> {
        self.sync_once_with_timeout_inner(Some(timeout)).await
    }

    async fn sync_once_with_timeout_inner(&self, timeout: Option<Duration>) -> Result<(), Error> {
        let _round = self.sync_guard.lock().await;
        // The default token is `ReusePrevious`: the SDK's own token, saved to
        // the store together with the state of the last processed response.
        // Passing our in-memory copy instead replayed a whole batch (and fired
        // its event handlers again) whenever a round was cancelled after the
        // SDK had processed the response but before we recorded `next_batch`.
        let mut settings = SyncSettings::default();
        if let Some(timeout) = timeout {
            settings = settings.timeout(timeout);
        }
        let sync = self.client.sync_once(settings);
        let response = if let Some(timeout) = timeout {
            sync_once_with_deadline(sync, timeout).await?
        } else {
            sync.await?
        };
        *self.sync_token.lock().await = Some(response.next_batch);
        Ok(())
    }

    /// Escape hatch: access the underlying [`matrix_sdk::Client`].
    pub fn inner(&self) -> &Client {
        &self.client
    }

    /// Whether a session is currently active.
    pub fn logged_in(&self) -> bool {
        !self.session_revoked.load(Ordering::SeqCst)
            && self.client.matrix_auth().session().is_some()
    }

    /// Clone the current sync token.
    pub async fn sync_token_clone(&self) -> Option<String> {
        self.sync_token.lock().await.clone()
    }

    /// Resolve a room by string ID.
    fn get_room_parsed(&self, room_id: &str) -> Result<Room, Error> {
        let room_id = <&RoomId>::try_from(room_id)
            .map_err(|e| Error::IdParse(format!("invalid room ID: {e}")))?;
        self.client
            .get_room(room_id)
            .ok_or_else(|| Error::Other(format!("room {} not found", room_id)))
    }

    /// Send a plain-text message. Returns the event ID.
    pub async fn send_text(&self, room_id: &str, body: &str) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::text_plain(body);
        self.send_room_message_content(&room, content).await
    }

    /// Send room-message content without asking matrix-sdk to persist a negative encryption
    /// lookup. Some browser stores can retain an SDK `Unknown` marker after same-device
    /// reauthentication even when sync has completed. In that case matrix-sdk's send path probes
    /// `m.room.encryption`, then persists the negative result before sending; a stale IndexedDB
    /// lock can leave that persistence waiting indefinitely.
    ///
    /// The bypass is limited to an explicit homeserver `M_NOT_FOUND`. A present
    /// encryption event fails closed until sync updates the local state; known local states remain
    /// on the SDK path, where encryption is applied as usual.
    async fn send_room_message_content(
        &self,
        room: &Room,
        content: RoomMessageEventContent,
    ) -> Result<String, Error> {
        match self.resolve_room_message_send_mode(room).await? {
            ResolvedRoomMessageSendMode::UseSdk => {
                let response = room.send(content).await?;
                Ok(response.event_id.to_string())
            }
            ResolvedRoomMessageSendMode::DirectPlaintext => {
                let event_id = self.send_direct_plaintext(room, &content).await?;
                self.remember_direct_room_message(room, &event_id, &content);
                Ok(event_id)
            }
        }
    }

    fn remember_direct_room_message(
        &self,
        room: &Room,
        event_id: &str,
        content: &RoomMessageEventContent,
    ) {
        let Some(sender) = self.client.user_id().map(ToString::to_string) else {
            return;
        };
        let timestamp = current_timestamp_millis();
        let Some(candidate) =
            outbound_last_message_candidate(event_id.to_owned(), sender, content, timestamp)
        else {
            return;
        };
        self.optimistic_last_messages
            .lock()
            .expect("optimistic message mutex poisoned")
            .insert(room.room_id().to_string(), candidate);
    }

    fn ensure_room_joined(room: &Room) -> Result<(), Error> {
        let room_state = room.state();
        if room_state != RoomState::Joined {
            return Err(Error::Other(format!(
                "cannot send to room {} while its state is {room_state:?}",
                room.room_id()
            )));
        }
        Ok(())
    }

    async fn resolve_room_message_send_mode(
        &self,
        room: &Room,
    ) -> Result<ResolvedRoomMessageSendMode, Error> {
        Self::ensure_room_joined(room)?;
        let encryption_state = room.encryption_state();
        info!(
            room_id = %room.room_id(),
            is_synced = room.is_synced(),
            encryption_state = ?encryption_state,
            "sending room message"
        );

        if room_message_send_mode(&encryption_state) == RoomMessageSendMode::UseSdk {
            return Ok(ResolvedRoomMessageSendMode::UseSdk);
        }

        send_mode_after_encryption_probe(self.probe_room_encryption_event(room).await?)
            .ok_or_else(|| Self::encryption_state_retry_error(room))
    }

    async fn resolve_attachment_send_mode(
        &self,
        room: &Room,
    ) -> Result<ResolvedRoomMessageSendMode, Error> {
        Self::ensure_room_joined(room)?;
        let encryption_state = room.encryption_state();
        info!(
            room_id = %room.room_id(),
            is_synced = room.is_synced(),
            encryption_state = ?encryption_state,
            "sending room attachment"
        );

        if attachment_send_mode(&encryption_state) == RoomMessageSendMode::UseSdk {
            return Ok(ResolvedRoomMessageSendMode::UseSdk);
        }

        send_mode_after_encryption_probe(self.probe_room_encryption_event(room).await?)
            .ok_or_else(|| Self::encryption_state_retry_error(room))
    }

    /// Probe for the room encryption state event without updating the SDK store.
    async fn probe_room_encryption_event(
        &self,
        room: &Room,
    ) -> Result<RoomEncryptionEventPresence, Error> {
        let request = GetStateEventRequest::new(
            room.room_id().to_owned(),
            StateEventType::RoomEncryption,
            String::new(),
        );
        match self.client.send(request).await {
            Ok(response) => {
                serde_json::from_str::<RoomEncryptionEventContent>(response.event_or_content.get())
                    .map_err(|error| {
                        Error::Other(format!(
                            "homeserver returned invalid m.room.encryption content for {}: {error}",
                            room.room_id()
                        ))
                    })?;
                Ok(RoomEncryptionEventPresence::Present)
            }
            Err(error) if error.client_api_error_kind() == Some(&ErrorKind::NotFound) => {
                Ok(RoomEncryptionEventPresence::Missing)
            }
            Err(error) => Err(error.into()),
        }
    }

    fn encryption_state_retry_error(room: &Room) -> Error {
        Error::Other(format!(
            "room {} is encrypted on the homeserver but its local encryption state is not ready; sync the room and retry",
            room.room_id()
        ))
    }

    async fn send_direct_plaintext<T>(&self, room: &Room, content: &T) -> Result<String, Error>
    where
        T: MessageLikeEventContent,
    {
        Self::ensure_room_joined(room)?;
        let request =
            plaintext_message_request(room.room_id().to_owned(), TransactionId::new(), content)?;
        let response = self.client.send(request).await?;
        Ok(response.event_id.to_string())
    }

    /// Send a message-like event of an arbitrary, non-standard `event_type` with arbitrary
    /// JSON `content`: for consumers that need their own event shape (e.g. an app-specific
    /// `io.example.foo` event) rather than one of this crate's fixed message/reaction shapes.
    /// Returns the event ID.
    pub async fn send_custom_event(
        &self,
        room_id: &str,
        event_type: &str,
        content: serde_json::Value,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        match self.resolve_room_message_send_mode(&room).await? {
            ResolvedRoomMessageSendMode::UseSdk => {
                let response = room.send_raw(event_type, content).await?;
                Ok(response.event_id.to_string())
            }
            ResolvedRoomMessageSendMode::DirectPlaintext => {
                let request = plaintext_raw_message_request(
                    room.room_id().to_owned(),
                    TransactionId::new(),
                    event_type,
                    &content,
                )?;
                let response = self.client.send(request).await?;
                Ok(response.event_id.to_string())
            }
        }
    }

    /// Updates `m.room.power_levels` so a custom message-like event type requires a specific
    /// power level, optionally adjusting explicit user power levels in the same state event.
    ///
    /// This is the authorization counterpart to [`Self::send_custom_event`]: apps can reserve
    /// a transport event type for a room role without ManyMatrix needing to know that event's
    /// schema. The homeserver enforces the resulting `events[event_type]` threshold before
    /// accepting future sends of that custom event type.
    pub async fn set_custom_event_power_levels(
        &self,
        room_id: &str,
        event_type: &str,
        required_power_level: i64,
        user_power_levels: Vec<(String, i64)>,
    ) -> Result<(), Error> {
        let event_type = event_type.trim();
        if event_type.is_empty() {
            return Err(Error::Other("custom event type must not be empty".into()));
        }

        let room = self.get_room_parsed(room_id)?;
        let required_power_level = required_power_level
            .try_into()
            .map_err(|err| Error::Other(format!("invalid required power level: {err}")))?;
        let mut power_levels = self.fetch_room_power_levels(&room).await?;
        power_levels.events.insert(
            TimelineEventType::from(event_type.to_owned()),
            required_power_level,
        );
        apply_user_power_levels(&mut power_levels, user_power_levels)?;

        room.send_state_event(power_levels).await?;
        Ok(())
    }

    /// Updates `m.room.power_levels.invite` so inviting users requires a specific room power
    /// level, optionally adjusting explicit user power levels in the same state event.
    pub async fn set_room_invite_power_level(
        &self,
        room_id: &str,
        required_power_level: i64,
        user_power_levels: Vec<(String, i64)>,
    ) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        let required_power_level = required_power_level
            .try_into()
            .map_err(|err| Error::Other(format!("invalid required power level: {err}")))?;
        let mut power_levels = self.fetch_room_power_levels(&room).await?;
        power_levels.invite = required_power_level;
        apply_user_power_levels(&mut power_levels, user_power_levels)?;

        room.send_state_event(power_levels).await?;
        Ok(())
    }

    /// Return the current `m.room.power_levels` state for a room in a consumer-friendly JSON
    /// snapshot, including the logged-in user's effective power level.
    ///
    /// The raw Matrix state is preserved under `raw`, while common thresholds are normalized with
    /// Matrix spec defaults so callers can preflight operations such as invites without re-encoding
    /// the power-level rules.
    pub async fn room_power_levels(&self, room_id: &str) -> Result<serde_json::Value, Error> {
        let room = self.get_room_parsed(room_id)?;
        let power_levels = self.fetch_room_power_levels(&room).await?;
        let raw = serde_json::to_value(&power_levels)?;
        let current_user_id = self
            .client
            .user_id()
            .ok_or_else(|| Error::Other("no logged-in user".into()))?
            .to_string();
        let users_default = power_level_field(&raw, "users_default", 0);
        let current_user_power_level =
            user_power_level(&raw, &current_user_id).unwrap_or(users_default);

        Ok(serde_json::json!({
            "roomId": room.room_id().to_string(),
            "currentUserId": current_user_id,
            "currentUserPowerLevel": current_user_power_level,
            "invite": power_level_field(&raw, "invite", 0),
            "kick": power_level_field(&raw, "kick", 50),
            "ban": power_level_field(&raw, "ban", 50),
            "redact": power_level_field(&raw, "redact", 50),
            "eventsDefault": power_level_field(&raw, "events_default", 0),
            "stateDefault": power_level_field(&raw, "state_default", 50),
            "usersDefault": users_default,
            "events": power_level_map(&raw, "events"),
            "users": power_level_map(&raw, "users"),
            "raw": raw,
        }))
    }

    async fn fetch_room_power_levels(
        &self,
        room: &Room,
    ) -> Result<RoomPowerLevelsEventContent, Error> {
        let request = GetStateEventRequest::new(
            room.room_id().to_owned(),
            StateEventType::RoomPowerLevels,
            String::new(),
        );
        let response = self.client.send(request).await?;
        Ok(serde_json::from_str(response.event_or_content.get())?)
    }

    /// List joined rooms.
    pub async fn joined_rooms(&self) -> Vec<RoomSummary> {
        let optimistic_last_messages = self.optimistic_last_messages.clone();
        join_all(self.client.joined_rooms().into_iter().map(|room| {
            let optimistic_last_messages = optimistic_last_messages.clone();
            async move {
                let room_id = room.room_id().to_string();
                let display_name = room
                    .display_name()
                    .await
                    .ok()
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| room_id.clone());
                let avatar_url = room.avatar_url().map(|u| u.to_string());
                let unread = room.unread_notification_counts();

                // Classic/sliding sync maintains this locally and filters out
                // reactions/state events. Do not issue one /messages request per
                // room on every UI refresh.
                let synced_last_message = room.latest_event().and_then(|latest| {
                    let event: serde_json::Value =
                        latest.event().kind.raw().deserialize_as_unchecked().ok()?;
                    Some(LastMessageCandidate {
                        event_id: event["event_id"].as_str().map(ToOwned::to_owned),
                        message: last_message_from_event(&event)?,
                    })
                });
                let mut optimistic = optimistic_last_messages
                    .lock()
                    .expect("optimistic message mutex poisoned");
                let (last_message, evict_optimistic) = merge_last_message_candidates(
                    synced_last_message.as_ref(),
                    optimistic.get(&room_id),
                );
                if evict_optimistic {
                    optimistic.remove(&room_id);
                }

                RoomSummary {
                    room_id,
                    display_name,
                    avatar_url,
                    last_message,
                    unread_count: unread.notification_count,
                    is_synced: room.is_synced(),
                }
            }
        }))
        .await
    }

    /// List pending room invitations.
    pub async fn invited_rooms(&self) -> Vec<RoomInvite> {
        let mut invites = Vec::new();
        for room in self.client.invited_rooms() {
            let room_id = room.room_id().to_string();
            let display_name = room
                .display_name()
                .await
                .ok()
                .map(|n| n.to_string())
                .unwrap_or_else(|| room_id.clone());
            let invite_details = room.invite_details().await.ok();
            let invited_user_id = invite_details
                .as_ref()
                .map(|details| details.invitee.user_id().to_string());
            let invited_display_name = invite_details
                .as_ref()
                .and_then(|details| details.invitee.display_name().map(ToOwned::to_owned));
            let invited_avatar_url = invite_details.as_ref().and_then(|details| {
                details
                    .invitee
                    .avatar_url()
                    .map(|avatar_url| avatar_url.to_string())
            });
            let inviter_user_id = invite_details.as_ref().map(|details| {
                details
                    .inviter
                    .as_ref()
                    .map(|inviter| inviter.user_id().to_string())
                    .unwrap_or_else(|| details.invitee.event().sender().to_string())
            });
            let inviter_display_name = invite_details
                .as_ref()
                .and_then(|details| details.inviter.as_ref())
                .map(|inviter| inviter.name().to_owned());
            let inviter_avatar_url = invite_details
                .as_ref()
                .and_then(|details| details.inviter.as_ref())
                .and_then(|inviter| {
                    inviter
                        .avatar_url()
                        .map(|avatar_url| avatar_url.to_string())
                });
            invites.push(RoomInvite {
                room_id,
                display_name,
                avatar_url: room.avatar_url().map(|url| url.to_string()),
                topic: room.topic(),
                canonical_alias: room.canonical_alias().map(|alias| alias.to_string()),
                alt_aliases: room
                    .alt_aliases()
                    .into_iter()
                    .map(|alias| alias.to_string())
                    .collect(),
                invited_user_id,
                invited_display_name,
                invited_avatar_url,
                inviter_user_id,
                inviter_display_name,
                inviter_avatar_url,
            });
        }
        invites
    }

    /// Paginate messages backward from a room.
    pub async fn get_messages(
        &self,
        room_id: &str,
        from_token: Option<&str>,
        limit: u32,
    ) -> Result<PaginatedMessages, Error> {
        let room = self.get_room_parsed(room_id)?;
        let mut options = MessagesOptions::backward();
        if let Some(token) = from_token {
            options = options.from(token);
        }
        options.limit = UInt::from(limit);

        let response = room.messages(options).await?;

        let messages = chronological_messages_from_backward(
            response
                .chunk
                .iter()
                .filter_map(|timeline_event| {
                    let event: serde_json::Value =
                        timeline_event.raw().deserialize_as_unchecked().ok()?;
                    message_event_from_json(&event, room_id)
                })
                .collect(),
        );

        let end_token = response.end;
        Ok(PaginatedMessages {
            messages,
            end_token,
        })
    }

    /// Return recent thread roots across joined rooms, newest activity first.
    ///
    /// Reply totals come from the homeserver's bundled `m.thread` aggregation.
    /// Unread totals come from a stateless zero-timeline sync snapshot, so they
    /// use server push-rule semantics without advancing an unprocessed cursor.
    pub async fn thread_index(&self, limit_per_room: u32) -> Result<Vec<ThreadSummary>, Error> {
        let rooms = self.client.joined_rooms();
        if rooms.is_empty() {
            return Ok(Vec::new());
        }
        let unread_counts = self
            .unread_thread_notification_counts()
            .await
            .ok()
            .flatten()
            .map(Arc::new);
        let limit = UInt::from(limit_per_room.clamp(1, 100));
        let room_results = stream::iter(rooms.into_iter().map(|room| {
            let unread_counts = unread_counts.clone();
            async move { room_thread_index(room, limit, unread_counts).await }
        }))
        .buffer_unordered(THREAD_INDEX_CONCURRENCY)
        .collect::<Vec<_>>()
        .await;

        let mut threads = Vec::new();
        for result in room_results {
            match result {
                Ok(room_threads) => {
                    threads.extend(room_threads);
                }
                Err(error) => return Err(error),
            }
        }
        threads.sort_by(|left, right| {
            thread_activity_timestamp(right)
                .cmp(&thread_activity_timestamp(left))
                .then_with(|| left.room_id.cmp(&right.room_id))
                .then_with(|| left.root.event_id.cmp(&right.root.event_id))
        });
        Ok(threads)
    }

    /// Load a page of relations for a thread, plus its root event.
    pub async fn get_thread_messages(
        &self,
        room_id: &str,
        thread_root_event_id: &str,
        from_token: Option<&str>,
        limit: u32,
    ) -> Result<PaginatedThreadMessages, Error> {
        let room = self.get_room_parsed(room_id)?;
        let root_event_id = <&EventId>::try_from(thread_root_event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        let root_timeline_event = room
            .event(root_event_id, None)
            .await
            .map_err(|e| Error::Other(format!("fetch thread root failed: {e}")))?;
        let root_json: serde_json::Value = root_timeline_event
            .raw()
            .deserialize_as_unchecked()
            .map_err(|e| Error::Other(format!("deserialize thread root failed: {e}")))?;
        let root = message_event_from_json(&root_json, room_id)
            .ok_or_else(|| Error::Other("thread root is not a room message".into()))?;

        let response = room
            .relations(
                root_event_id.to_owned(),
                RelationsOptions {
                    from: from_token.map(ToOwned::to_owned),
                    dir: Direction::Backward,
                    limit: Some(UInt::from(limit.clamp(1, 100))),
                    include_relations: IncludeRelations::AllRelations,
                    recurse: true,
                },
            )
            .await?;
        let messages = chronological_messages_from_backward(
            response
                .chunk
                .iter()
                .filter_map(|timeline_event| {
                    let event: serde_json::Value =
                        timeline_event.raw().deserialize_as_unchecked().ok()?;
                    message_event_from_json(&event, room_id)
                })
                .collect(),
        );

        Ok(PaginatedThreadMessages {
            root,
            messages,
            end_token: response.next_batch_token,
        })
    }

    /// Send a read receipt scoped to a single Matrix thread.
    pub async fn send_thread_read_receipt(
        &self,
        room_id: &str,
        thread_root_event_id: &str,
        event_id: &str,
    ) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        let thread_root_event_id = <&EventId>::try_from(thread_root_event_id)
            .map_err(|e| Error::IdParse(format!("invalid thread root event ID: {e}")))?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        room.send_single_receipt(
            ReceiptType::Read,
            ReceiptThread::Thread(thread_root_event_id.to_owned()),
            event_id.to_owned(),
        )
        .await?;
        Ok(())
    }

    async fn unread_thread_notification_counts(
        &self,
    ) -> Result<Option<HashMap<(String, String), u64>>, Error> {
        let mut cache = self.thread_unread_cache.lock().await;
        if cache.supported.is_none() {
            let versions = self.client.fetch_server_versions(None).await?;
            cache.supported = Some(
                versions
                    .versions
                    .iter()
                    .filter_map(|version| version.parse::<MatrixVersion>().ok())
                    .any(|version| version.is_superset_of(MatrixVersion::V1_4)),
            );
        }
        if cache.supported != Some(true) {
            return Ok(None);
        }

        // Never advance a secondary /sync cursor. Reusing next_batch without
        // first passing the response through matrix-sdk would acknowledge and
        // delete to-device events before the real sync loop can process them.
        // This stateless snapshot is costlier, but discarding its next_batch is
        // safe until unread-thread aggregates are available from SDK sync data.
        let response = self.fetch_thread_unread_sync().await?;
        let mut counts = HashMap::new();
        for (room_id, room) in response.rooms.join {
            let room_id = room_id.to_string();
            for (thread_root, count) in room.unread_thread_notifications {
                let count = count.notification_count.ok_or_else(|| {
                    Error::Other(
                        "thread unread sync omitted a notification count for a reported root"
                            .into(),
                    )
                })?;
                counts.insert((room_id.clone(), thread_root.to_string()), u64::from(count));
            }
        }
        Ok(Some(counts))
    }

    async fn fetch_thread_unread_sync(
        &self,
    ) -> Result<matrix_sdk::ruma::api::client::sync::sync_events::v3::Response, Error> {
        Ok(self.client.send(thread_unread_sync_request()).await?)
    }

    /// Create a new room with the given options.
    pub async fn create_room(&self, options: CreateRoomOptions) -> Result<String, Error> {
        let request = create_room_request_from_options(options)?;
        let room = self.client.create_room(request).await?;
        Ok(room.room_id().to_string())
    }

    /// Join a room by ID or alias.
    pub async fn join_room(&self, room_id_or_alias: &str) -> Result<String, Error> {
        let room = if room_id_or_alias.starts_with('!') {
            let room_id = <&RoomId>::try_from(room_id_or_alias)
                .map_err(|e| Error::IdParse(format!("invalid room ID: {e}")))?;
            self.client.join_room_by_id(room_id).await?
        } else {
            let alias = <&RoomOrAliasId>::try_from(room_id_or_alias)
                .map_err(|e| Error::IdParse(format!("invalid room alias: {e}")))?;
            self.client.join_room_by_id_or_alias(alias, &[]).await?
        };
        Ok(room.room_id().to_string())
    }

    /// Invite a user to a room.
    pub async fn invite(&self, room_id: &str, user_id: &str) -> Result<(), Error> {
        let room_id = <&RoomId>::try_from(room_id)
            .map_err(|e| Error::IdParse(format!("invalid room ID: {e}")))?;
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let room = self
            .client
            .get_room(room_id)
            .ok_or_else(|| Error::Other(format!("room {} not found", room_id)))?;
        room.invite_user_by_id(user_id).await?;
        Ok(())
    }

    /// Leave a room.
    pub async fn leave_room(&self, room_id: &str) -> Result<(), Error> {
        let room_id = <&RoomId>::try_from(room_id)
            .map_err(|e| Error::IdParse(format!("invalid room ID: {e}")))?;
        let room = self
            .client
            .get_room(room_id)
            .ok_or_else(|| Error::Other(format!("room {} not found", room_id)))?;
        room.leave().await?;
        self.optimistic_last_messages
            .lock()
            .expect("optimistic message mutex poisoned")
            .remove(room_id.as_str());
        Ok(())
    }

    /// Send an HTML message. Returns the event ID.
    pub async fn send_html(
        &self,
        room_id: &str,
        plain_body: &str,
        html_body: &str,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::text_html(plain_body, html_body);
        self.send_room_message_content(&room, content).await
    }

    /// Send a notice. Returns the event ID.
    pub async fn send_notice(&self, room_id: &str, body: &str) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::notice_plain(body);
        self.send_room_message_content(&room, content).await
    }

    /// Send an emote (/me). Returns the event ID.
    pub async fn send_emote(&self, room_id: &str, body: &str) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::emote_plain(body);
        self.send_room_message_content(&room, content).await
    }

    /// Edit a previously sent message.
    pub async fn edit_message(
        &self,
        room_id: &str,
        event_id: &str,
        new_body: &str,
    ) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        let metadata = matrix_sdk::ruma::events::room::message::ReplacementMetadata::new(
            event_id.to_owned(),
            None,
        );
        let edit_content = RoomMessageEventContent::text_plain(new_body).make_replacement(metadata);
        self.send_room_message_content(&room, edit_content).await?;
        Ok(())
    }

    /// Reply to a message. Returns the event ID.
    pub async fn reply_to(
        &self,
        room_id: &str,
        event_id: &str,
        body: &str,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        let original = self.fetch_original_message(&room, event_id).await?;
        let reply_content = RoomMessageEventContentWithoutRelation::text_plain(body).make_reply_to(
            &original,
            ForwardThread::Yes,
            AddMentions::Yes,
        );
        self.send_room_message_content(&room, reply_content).await
    }

    /// React to an event. Returns the reaction event ID.
    pub async fn send_reaction(
        &self,
        room_id: &str,
        event_id: &str,
        key: &str,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        let annotation = Annotation::new(event_id.to_owned(), key.to_owned());
        let content = ReactionEventContent::new(annotation);
        // matrix-sdk leaves reactions plaintext even in encrypted rooms, but its
        // generic send path still resolves the room encryption state first. Sending the same
        // plaintext event directly avoids that unnecessary store lookup.
        self.send_direct_plaintext(&room, &content).await
    }

    /// Redact an event.
    pub async fn redact(
        &self,
        room_id: &str,
        event_id: &str,
        reason: Option<&str>,
    ) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        room.redact(event_id, reason, None).await?;
        Ok(())
    }

    /// Send a threaded reply. Returns the event ID.
    pub async fn send_thread_reply(
        &self,
        room_id: &str,
        thread_root_event_id: &str,
        in_reply_to_event_id: &str,
        body: &str,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let thread_root_event_id = <&EventId>::try_from(thread_root_event_id)
            .map_err(|e| Error::IdParse(format!("invalid thread root event ID: {e}")))?;
        let in_reply_to_event_id = <&EventId>::try_from(in_reply_to_event_id)
            .map_err(|e| Error::IdParse(format!("invalid reply target event ID: {e}")))?;
        let target = self
            .fetch_original_message(&room, in_reply_to_event_id)
            .await?;
        let thread_content =
            thread_reply_content(body, thread_root_event_id, &target.event_id, &target.sender);
        self.send_room_message_content(&room, thread_content).await
    }

    /// Fetch an original room message event for reply/thread construction.
    async fn fetch_original_message(
        &self,
        room: &Room,
        event_id: &EventId,
    ) -> Result<matrix_sdk::ruma::events::room::message::OriginalRoomMessageEvent, Error> {
        let timeline_event = room
            .event(event_id, None)
            .await
            .map_err(|e| Error::Other(format!("fetch event failed: {e}")))?;
        let full_event: AnyTimelineEvent = timeline_event
            .raw()
            .deserialize_as_unchecked()
            .map_err(|e| Error::Other(format!("deserialize event failed: {e}")))?;
        match full_event {
            AnyTimelineEvent::MessageLike(AnyMessageLikeEvent::RoomMessage(
                MessageLikeEvent::Original(original),
            )) => Ok(original),
            _ => Err(Error::Other("event is not an original room message".into())),
        }
    }

    /// Kick a user from a room.
    pub async fn kick(
        &self,
        room_id: &str,
        user_id: &str,
        reason: Option<&str>,
    ) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let room = self.get_room_parsed(room_id)?;
        room.kick_user(user_id, reason).await?;
        Ok(())
    }

    /// Ban a user from a room.
    pub async fn ban(
        &self,
        room_id: &str,
        user_id: &str,
        reason: Option<&str>,
    ) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let room = self.get_room_parsed(room_id)?;
        room.ban_user(user_id, reason).await?;
        Ok(())
    }

    /// Get the room's name (from room state), or None if not set.
    pub fn room_name(&self, room_id: &str) -> Result<Option<String>, Error> {
        let room = self.get_room_parsed(room_id)?;
        Ok(room.name())
    }

    /// Get the room's topic, or None if not set.
    pub fn room_topic(&self, room_id: &str) -> Result<Option<String>, Error> {
        let room = self.get_room_parsed(room_id)?;
        Ok(room.topic())
    }

    /// Get the room's avatar URL (mxc:// URI), or None if not set.
    pub fn room_avatar_url(&self, room_id: &str) -> Result<Option<String>, Error> {
        let room = self.get_room_parsed(room_id)?;
        Ok(room.avatar_url().map(|u| u.to_string()))
    }

    /// Get stable room identity details.
    pub fn room_details(&self, room_id: &str) -> Result<RoomDetails, Error> {
        let room = self.get_room_parsed(room_id)?;
        Ok(room_details_from_room(&room))
    }

    /// Get the list of joined member user IDs for a room.
    pub async fn room_members(&self, room_id: &str) -> Result<Vec<String>, Error> {
        let room = self.get_room_parsed(room_id)?;
        let response = self
            .client
            .send(JoinedMembersRequest::new(room.room_id().to_owned()))
            .await?;
        Ok(response
            .joined
            .keys()
            .map(|user_id| user_id.to_string())
            .collect())
    }

    /// Probe Matrix version and capability support for this homeserver.
    pub async fn server_capabilities(&self) -> Result<ServerCapabilities, Error> {
        let versions_response = self.client.fetch_server_versions(None).await?;
        let versions = versions_response.versions.clone();
        let unstable_features = versions_response.unstable_features.clone();
        let raw_versions = serde_json::json!({
            "versions": versions.clone(),
            "unstable_features": unstable_features.clone(),
        });
        let raw_capabilities = if self.client.session().is_some() {
            match self.client.get_capabilities().await {
                Ok(capabilities) => Some(serde_json::to_value(&capabilities)?),
                Err(_) => None,
            }
        } else {
            None
        };

        Ok(ServerCapabilities::from_raw(
            // The canonical form used by `StoredSession`; `Client::homeserver()`
            // renders the same URL with a trailing slash.
            self.homeserver.clone(),
            versions,
            unstable_features,
            raw_versions,
            raw_capabilities,
        ))
    }

    /// Send a read receipt for the given event in the given room.
    pub async fn send_read_receipt(&self, room_id: &str, event_id: &str) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        room.send_single_receipt(ReceiptType::Read, ReceiptThread::Main, event_id.to_owned())
            .await?;
        Ok(())
    }

    /// Send a typing indicator.
    pub async fn send_typing(&self, room_id: &str, typing: bool) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        room.typing_notice(typing).await?;
        Ok(())
    }

    /// Upload a file attachment to a room. Returns the event ID.
    pub async fn upload_media(
        &self,
        room_id: &str,
        filename: &str,
        mime_type: &str,
        data: Vec<u8>,
    ) -> Result<String, Error> {
        let mime: mime::Mime = mime_type
            .parse()
            .map_err(|e| Error::Other(format!("invalid MIME type: {e}")))?;
        let room = self.get_room_parsed(room_id)?;
        match self.resolve_attachment_send_mode(&room).await? {
            ResolvedRoomMessageSendMode::UseSdk => {
                let response = room
                    .send_attachment(filename, &mime, data, AttachmentConfig::new())
                    .await?;
                Ok(response.event_id.to_string())
            }
            ResolvedRoomMessageSendMode::DirectPlaintext => {
                let data_len = data.len();
                let upload = self.client.media().upload(&mime, data, None).await?;

                // Encryption can be enabled while a potentially long upload is in flight. A
                // second homeserver probe is required before publishing the plain MXC URI.
                let second_probe = self.probe_room_encryption_event(&room).await?;
                if !can_publish_plain_attachment(&room.encryption_state(), second_probe) {
                    return Err(Self::encryption_state_retry_error(&room));
                }

                let content =
                    plain_attachment_content(filename, &mime, upload.content_uri, data_len);
                let event_id = self.send_direct_plaintext(&room, &content).await?;
                self.remember_direct_room_message(&room, &event_id, &content);
                Ok(event_id)
            }
        }
    }

    /// Download media content by mxc:// URI.
    pub async fn download_media(&self, mxc_uri: &str) -> Result<Vec<u8>, Error> {
        self.download_media_from_source(plain_media_source_from_mxc(mxc_uri)?)
            .await
    }

    /// Download a plain or encrypted Matrix attachment from its complete
    /// serialized `MediaSource` descriptor.
    pub async fn download_media_source(
        &self,
        media_source: &serde_json::Value,
    ) -> Result<Vec<u8>, Error> {
        let source: MediaSource = serde_json::from_value(media_source.clone())
            .map_err(|error| Error::Other(format!("invalid media source: {error}")))?;
        self.download_media_from_source(source).await
    }

    async fn download_media_from_source(&self, source: MediaSource) -> Result<Vec<u8>, Error> {
        let uri = match &source {
            MediaSource::Plain(uri) => uri.as_ref(),
            MediaSource::Encrypted(file) => file.url.as_ref(),
        };
        let ciphertext = download_bounded_media(&self.client, uri).await?;
        match source {
            MediaSource::Plain(_) => Ok(ciphertext),
            MediaSource::Encrypted(file) => {
                let capacity = ciphertext.len();
                let mut cursor = Cursor::new(ciphertext);
                let mut decryptor = matrix_sdk_crypto::AttachmentDecryptor::new(
                    &mut cursor,
                    file.as_ref().clone().into(),
                )
                .map_err(|error| Error::Other(format!("invalid encrypted attachment: {error}")))?;
                let mut plaintext = Vec::with_capacity(capacity);
                decryptor.read_to_end(&mut plaintext).map_err(|error| {
                    Error::Other(format!("could not decrypt Matrix attachment: {error}"))
                })?;
                validate_media_download_size(plaintext.len())?;
                Ok(plaintext)
            }
        }
    }

    /// Fetch a thumbnail by mxc:// URI at the requested dimensions.
    pub async fn get_thumbnail(
        &self,
        mxc_uri: &str,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, Error> {
        self.client
            .media()
            .get_media_content(
                &MediaRequestParameters {
                    source: plain_media_source_from_mxc(mxc_uri)?,
                    format: MediaFormat::Thumbnail(MediaThumbnailSettings::new(
                        UInt::from(width),
                        UInt::from(height),
                    )),
                },
                true,
            )
            .await
            .map_err(Error::from)
    }

    /// Register an HTTP pusher for push notifications.
    pub async fn register_pusher(
        &self,
        app_id: &str,
        push_key: &str,
        app_display_name: &str,
        device_display_name: &str,
        push_url: &str,
        lang: &str,
    ) -> Result<(), Error> {
        use matrix_sdk::ruma::api::client::push::{PusherIds, PusherInit, PusherKind};
        use matrix_sdk::ruma::push::HttpPusherData;

        let pusher_init = PusherInit {
            ids: PusherIds::new(push_key.to_owned(), app_id.to_owned()),
            kind: PusherKind::Http(HttpPusherData::new(push_url.to_owned())),
            app_display_name: app_display_name.to_owned(),
            device_display_name: device_display_name.to_owned(),
            profile_tag: None,
            lang: lang.to_owned(),
        };
        self.client.pusher().set(pusher_init.into()).await?;
        Ok(())
    }

    /// Enable E2EE on a room.
    pub async fn enable_encryption(&self, room_id: &str) -> Result<(), Error> {
        let room = self.get_room_parsed(room_id)?;
        room.enable_encryption().await?;
        Ok(())
    }

    /// Start SAS verification with a user's device. Returns the flow ID.
    pub async fn start_verification(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<String, Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        // Device IDs are opaque strings in the spec; ruma does not validate them.
        let device_id = <&DeviceId>::from(device_id);
        let device = self
            .client
            .encryption()
            .get_device(user_id, device_id)
            .await
            .map_err(|e| Error::Other(format!("get device failed: {e}")))?
            .ok_or_else(|| Error::Other("device not found".into()))?;
        let request = device.request_verification().await?;
        Ok(request.flow_id().to_string())
    }

    /// Accept an incoming SAS verification request.
    pub async fn accept_verification(&self, user_id: &str, flow_id: &str) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let request = self
            .client
            .encryption()
            .get_verification_request(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification request not found".into()))?;
        request.accept().await?;
        Ok(())
    }

    /// Transition an accepted verification request into a SAS verification flow.
    pub async fn start_sas(&self, user_id: &str, flow_id: &str) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let request = self
            .client
            .encryption()
            .get_verification_request(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification request not found".into()))?;
        request
            .start_sas()
            .await?
            .ok_or_else(|| Error::Other("verification request is not ready for SAS".into()))?;
        Ok(())
    }

    /// Accept an in-progress SAS verification so short auth strings can be shown.
    pub async fn accept_sas(&self, user_id: &str, flow_id: &str) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let verification = self
            .client
            .encryption()
            .get_verification(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification not found".into()))?;
        let sas = verification
            .sas()
            .ok_or_else(|| Error::Other("not a SAS verification".into()))?;
        sas.accept().await?;
        Ok(())
    }

    /// Get the SAS emoji set for visual comparison during verification.
    pub async fn get_sas_emojis(&self, user_id: &str, flow_id: &str) -> Result<SasEmojis, Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let verification = self
            .client
            .encryption()
            .get_verification(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification not found".into()))?;
        let sas = verification
            .sas()
            .ok_or_else(|| Error::Other("not a SAS verification".into()))?;
        let emojis = sas
            .emoji()
            .ok_or_else(|| Error::Other("SAS emojis not available yet".into()))?;
        let emoji_vec: Vec<SasEmoji> = emojis
            .iter()
            .map(|e| SasEmoji {
                symbol: e.symbol.to_string(),
                description: e.description.to_string(),
            })
            .collect();
        Ok(SasEmojis { emojis: emoji_vec })
    }

    /// Confirm the SAS verification after comparing emojis.
    pub async fn confirm_sas(&self, user_id: &str, flow_id: &str) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        let verification = self
            .client
            .encryption()
            .get_verification(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification not found".into()))?;
        let sas = verification
            .sas()
            .ok_or_else(|| Error::Other("not a SAS verification".into()))?;
        sas.confirm().await?;
        Ok(())
    }

    /// Cancel an ongoing verification flow.
    pub async fn cancel_verification(&self, user_id: &str, flow_id: &str) -> Result<(), Error> {
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::IdParse(format!("invalid user ID: {e}")))?;
        // Between `start_verification`/`accept_verification` and `start_sas`
        // there is only a `VerificationRequest`; `get_verification` returns
        // nothing until the SAS stage exists, so look for both.
        if let Some(verification) = self
            .client
            .encryption()
            .get_verification(user_id, flow_id)
            .await
        {
            let sas = verification
                .sas()
                .ok_or_else(|| Error::Other("not a SAS verification".into()))?;
            sas.cancel().await?;
            return Ok(());
        }
        let request = self
            .client
            .encryption()
            .get_verification_request(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification not found".into()))?;
        request.cancel().await?;
        Ok(())
    }

    /// Bootstrap cross-signing keys. Call once after initial login.
    pub async fn bootstrap_cross_signing(&self) -> Result<(), Error> {
        self.client
            .encryption()
            .bootstrap_cross_signing(None)
            .await?;
        Ok(())
    }

    /// Create a server-side key backup.
    pub async fn setup_key_backup(&self) -> Result<(), Error> {
        self.client
            .encryption()
            .backups()
            .create()
            .await
            .map_err(|e| Error::Other(format!("setup key backup failed: {e}")))?;
        Ok(())
    }

    /// Enable secret storage and key backup recovery. Returns the recovery key.
    pub async fn enable_recovery(&self) -> Result<String, Error> {
        self.client
            .encryption()
            .recovery()
            .enable()
            .await
            .map_err(|e| Error::Other(format!("enable recovery failed: {e}")))
    }

    /// Block until all locally-created room keys have finished uploading to
    /// the server-side backup. Upload happens on a background task that
    /// `sync_once` only *signals*, so callers that need a just-created room
    /// key to be durably backed up before proceeding (e.g. before a second
    /// device restores from backup) must await this rather than polling sync.
    pub async fn wait_for_backup_upload(&self) -> Result<(), Error> {
        self.client
            .encryption()
            .backups()
            .wait_for_steady_state()
            .await
            .map_err(|e| Error::Other(format!("waiting for backup upload failed: {e}")))
    }

    /// Restore room keys from backup using the recovery key.
    pub async fn restore_key_backup(&self, recovery_key: &str) -> Result<(), Error> {
        self.client
            .encryption()
            .recovery()
            .recover(recovery_key)
            .await
            .map_err(|e| Error::Other(format!("restore key backup failed: {e}")))?;
        Ok(())
    }

    /// Returns the current user's Matrix ID (e.g. `@alice:example.com`), or `None` if not logged in.
    pub fn current_user_id(&self) -> Option<String> {
        self.client.user_id().map(|id| id.to_string())
    }

    /// Check whether a room has encryption enabled.
    pub async fn is_room_encrypted(&self, room_id: &str) -> Result<bool, Error> {
        let room = self.get_room_parsed(room_id)?;
        let encryption_state = room.encryption_state();
        if encryption_state.is_unknown() {
            Ok(self.probe_room_encryption_event(&room).await?
                == RoomEncryptionEventPresence::Present)
        } else {
            Ok(encryption_state.is_encrypted())
        }
    }

    /// Register a callback for incoming room messages.
    pub fn on_message<F>(&self, callback: F)
    where
        F: Fn(MessageEvent) + SendOutsideWasm + SyncOutsideWasm + 'static,
    {
        let callback = Arc::new(callback);
        let message_callback = callback.clone();
        self.client
            .add_event_handler(move |ev: SyncRoomMessageEvent, room: Room| {
                let callback = message_callback.clone();
                async move {
                    if let SyncRoomMessageEvent::Original(msg) = ev {
                        let replacement = msg.content.relates_to.as_ref().and_then(|rel| {
                            if let Relation::Replacement(replacement) = rel {
                                Some(replacement)
                            } else {
                                None
                            }
                        });
                        let content_msgtype = replacement
                            .map(|replacement| &replacement.new_content.msgtype)
                            .unwrap_or(&msg.content.msgtype);
                        let msgtype = content_msgtype.msgtype().to_owned();
                        let body = content_msgtype.body().to_owned();
                        let formatted_body = formatted_body_for_msgtype(content_msgtype);
                        let in_reply_to = msg.content.relates_to.as_ref().and_then(|rel| {
                            match rel {
                                Relation::Reply { in_reply_to } => {
                                    Some(in_reply_to.event_id.to_string())
                                }
                                // A thread reply carries `m.in_reply_to` too, but
                                // only as a real reply target when it is not the
                                // fallback pointer that plain thread messages set
                                // for clients without thread support.
                                Relation::Thread(thread) if !thread.is_falling_back => thread
                                    .in_reply_to
                                    .as_ref()
                                    .map(|reply| reply.event_id.to_string()),
                                _ => None,
                            }
                        });
                        let thread_root = msg.content.relates_to.as_ref().and_then(|rel| {
                            if let Relation::Thread(thread) = rel {
                                Some(thread.event_id.to_string())
                            } else {
                                None
                            }
                        });
                        let replaces_event_id =
                            replacement.map(|replacement| replacement.event_id.to_string());
                        let (mxc_uri, media_source, filename, file_size) =
                            media_details_for_msgtype(content_msgtype);
                        let message = MessageEvent {
                            event_id: msg.event_id.to_string(),
                            room_id: room.room_id().to_string(),
                            sender: msg.sender.to_string(),
                            body,
                            formatted_body,
                            msgtype,
                            timestamp: msg.origin_server_ts.get().into(),
                            in_reply_to,
                            thread_root,
                            replaces_event_id,
                            redacts_event_id: None,
                            edited_at: None,
                            mxc_uri,
                            media_source,
                            filename,
                            file_size,
                        };
                        callback(message);
                    }
                }
            });
        self.client
            .add_event_handler(move |ev: SyncRoomRedactionEvent, room: Room| {
                let callback = callback.clone();
                async move {
                    let SyncRoomRedactionEvent::Original(redaction) = ev else {
                        return;
                    };
                    let Some(target) = redaction
                        .redacts
                        .as_ref()
                        .or(redaction.content.redacts.as_ref())
                    else {
                        return;
                    };
                    callback(MessageEvent {
                        event_id: redaction.event_id.to_string(),
                        room_id: room.room_id().to_string(),
                        sender: redaction.sender.to_string(),
                        body: String::new(),
                        formatted_body: None,
                        msgtype: "m.redaction".into(),
                        timestamp: redaction.origin_server_ts.get().into(),
                        in_reply_to: None,
                        thread_root: None,
                        replaces_event_id: None,
                        redacts_event_id: Some(target.to_string()),
                        edited_at: None,
                        mxc_uri: None,
                        media_source: None,
                        filename: None,
                        file_size: None,
                    });
                }
            });
    }

    /// Register a callback for incoming reactions.
    pub fn on_reaction<F>(&self, callback: F)
    where
        F: Fn(ReactionEvent) + SendOutsideWasm + SyncOutsideWasm + 'static,
    {
        let callback = Arc::new(callback);
        self.client.add_event_handler(
            move |ev: OriginalSyncMessageLikeEvent<ReactionEventContent>, room: Room| {
                let callback = callback.clone();
                async move {
                    let reaction = ReactionEvent {
                        event_id: ev.event_id.to_string(),
                        room_id: room.room_id().to_string(),
                        sender: ev.sender.to_string(),
                        relates_to_event_id: ev.content.relates_to.event_id.to_string(),
                        key: ev.content.relates_to.key,
                        timestamp: ev.origin_server_ts.get().into(),
                    };
                    callback(reaction);
                }
            },
        );
    }

    /// Register a callback for read receipts.
    pub fn on_receipt<F>(&self, callback: F)
    where
        F: Fn(ReceiptEvent) + SendOutsideWasm + SyncOutsideWasm + 'static,
    {
        let callback = Arc::new(callback);
        self.client.add_event_handler(
            move |ev: SyncEphemeralRoomEvent<ReceiptEventContent>, room: Room| {
                let callback = callback.clone();
                async move {
                    let room_id = room.room_id().to_string();
                    for (event_id, receipts) in ev.content.iter() {
                        for (receipt_type, user_receipts) in receipts.iter() {
                            for (user_id, receipt) in user_receipts.iter() {
                                let receipt_event = ReceiptEvent {
                                    room_id: room_id.clone(),
                                    user_id: user_id.to_string(),
                                    event_id: event_id.to_string(),
                                    receipt_type: receipt_type.to_string(),
                                    thread_id: receipt.thread.as_str().map(ToOwned::to_owned),
                                    timestamp: receipt.ts.map(|ts| ts.get().into()),
                                };
                                callback(receipt_event);
                            }
                        }
                    }
                }
            },
        );
    }

    /// Register a callback for incoming custom (non-standard) message-like events whose
    /// `event_type` matches `event_type` exactly. Registers on the raw, undeserialized event
    /// so it works for any event type (including ones this crate has no typed model for)
    /// rather than only the fixed shapes `on_message`/`on_reaction` cover.
    pub fn on_custom_event<F>(&self, event_type: &str, callback: F)
    where
        F: Fn(CustomEvent) + SendOutsideWasm + SyncOutsideWasm + 'static,
    {
        let callback = Arc::new(callback);
        let wanted_type = event_type.to_owned();
        self.client
            .add_event_handler(move |ev: Raw<AnySyncMessageLikeEvent>, room: Room| {
                let callback = callback.clone();
                let wanted_type = wanted_type.clone();
                async move {
                    let actual_type: Option<String> = ev.get_field("type").ok().flatten();
                    if actual_type.as_deref() != Some(wanted_type.as_str()) {
                        return;
                    }
                    let event_id: Option<String> = ev.get_field("event_id").ok().flatten();
                    let sender: Option<String> = ev.get_field("sender").ok().flatten();
                    let timestamp: Option<u64> = ev.get_field("origin_server_ts").ok().flatten();
                    let content: Option<serde_json::Value> = ev.get_field("content").ok().flatten();
                    let (Some(event_id), Some(sender), Some(timestamp), Some(content)) =
                        (event_id, sender, timestamp, content)
                    else {
                        return;
                    };
                    callback(CustomEvent {
                        event_id,
                        room_id: room.room_id().to_string(),
                        sender,
                        event_type: wanted_type,
                        content,
                        timestamp,
                    });
                }
            });
    }
}

#[cfg(not(target_family = "wasm"))]
impl ManyMatrixClient {
    /// Build a new client pointing at `homeserver_url`, storing state under `store_path`.
    pub async fn new(homeserver_url: &str, store_path: impl AsRef<Path>) -> Result<Self, Error> {
        Self::new_with_options(homeserver_url, store_path, ClientOptions::default()).await
    }

    /// Build a new client with explicit native transport options.
    pub async fn new_with_options(
        homeserver_url: &str,
        store_path: impl AsRef<Path>,
        options: ClientOptions,
    ) -> Result<Self, Error> {
        let store_path = store_path.as_ref();
        let homeserver = canonical_homeserver_url(homeserver_url)?;
        let mut builder = Client::builder()
            .homeserver_url(&homeserver)
            .sqlite_store(store_path, None)
            .handle_refresh_tokens()
            .with_encryption_settings(key_backup_encryption_settings());
        let custom_root_certificates =
            custom_root_certificates_from_paths(&options.custom_root_certificate_paths)?;
        if !custom_root_certificates.is_empty() {
            builder = builder.add_root_certificates(custom_root_certificates);
        }
        let client = builder.build().await?;
        let latest_session_json = Arc::new(StdMutex::new(None));
        let session_update_callback = Arc::new(StdMutex::new(None));
        {
            let homeserver = homeserver.clone();
            let latest_session_json = latest_session_json.clone();
            let session_update_callback = session_update_callback.clone();
            client.set_session_callbacks(
                Box::new(|client| {
                    client.session_tokens().ok_or_else(
                        || -> Box<dyn std::error::Error + Send + Sync> {
                            "no active Matrix session tokens".into()
                        },
                    )
                }),
                Box::new(move |client| {
                    let session = client.matrix_auth().session().ok_or_else(
                        || -> Box<dyn std::error::Error + Send + Sync> {
                            "no active Matrix session".into()
                        },
                    )?;
                    let stored = StoredSession {
                        homeserver: homeserver.clone(),
                        session,
                    };
                    ManyMatrixClient::publish_session_json(
                        &latest_session_json,
                        &session_update_callback,
                        &stored,
                    )
                    .map_err(
                        |error| -> Box<dyn std::error::Error + Send + Sync> { Box::new(error) },
                    )
                }),
            )?;
        }
        Ok(Self {
            client,
            homeserver,
            sync_token: Arc::new(Mutex::new(None)),
            sync_guard: Arc::new(Mutex::new(())),
            latest_session_json,
            session_update_callback,
            session_revoked: Arc::new(AtomicBool::new(false)),
            sync_logging_attached: Arc::new(AtomicBool::new(false)),
            optimistic_last_messages: Arc::new(StdMutex::new(HashMap::new())),
            thread_unread_cache: Arc::new(Mutex::new(ThreadUnreadCache::default())),
            store_path: store_path.to_owned(),
        })
    }
}

/// `matrix-sdk`'s default `BackupDownloadStrategy` is `Manual`, restoring a
/// backup via a recovery key (`restore_key_backup`) imports cross-signing
/// secrets but fetches zero room keys unless this is set to `OneShot`,
/// silently leaving restored clients unable to decrypt history.
fn key_backup_encryption_settings() -> EncryptionSettings {
    EncryptionSettings {
        backup_download_strategy: BackupDownloadStrategy::OneShot,
        ..Default::default()
    }
}

fn create_room_request_from_options(
    options: CreateRoomOptions,
) -> Result<CreateRoomRequest, Error> {
    let mut request = CreateRoomRequest::new();
    request.name = options.name;
    request.topic = options.topic;

    // Parse invite user IDs from strings.
    request.invite = options
        .invite
        .iter()
        .map(|id| {
            <&UserId>::try_from(id.as_str())
                .map(|u| u.to_owned())
                .map_err(|e| Error::IdParse(format!("invalid user ID '{}': {}", id, e)))
        })
        .collect::<Result<Vec<_>, _>>()?;

    let (visibility, preset) = match options.visibility {
        RoomVisibility::Public => (Visibility::Public, RoomPreset::PublicChat),
        RoomVisibility::Private => (Visibility::Private, RoomPreset::PrivateChat),
    };
    request.visibility = visibility;
    request.preset = Some(preset);

    Ok(request)
}

fn plain_media_source_from_mxc(mxc_uri: &str) -> Result<MediaSource, Error> {
    // `&str -> &MxcUri` never fails (ruma only wraps the string), so the
    // actual syntax check has to be an explicit `validate()`.
    let uri = <&MxcUri>::from(mxc_uri);
    uri.validate()
        .map_err(|e| Error::IdParse(format!("invalid MXC URI: {e}")))?;
    Ok(MediaSource::Plain(uri.to_owned()))
}

fn formatted_body_for_msgtype(msgtype: &MessageType) -> Option<String> {
    match msgtype {
        MessageType::Text(t) => t.formatted.as_ref().map(|f| f.body.clone()),
        MessageType::Notice(n) => n.formatted.as_ref().map(|f| f.body.clone()),
        MessageType::Emote(e) => e.formatted.as_ref().map(|f| f.body.clone()),
        _ => None,
    }
}

fn media_details_for_msgtype(
    msgtype: &MessageType,
) -> (
    Option<String>,
    Option<serde_json::Value>,
    Option<String>,
    Option<u64>,
) {
    let (source, filename, size) = match msgtype {
        MessageType::Image(img) => {
            let size = img.info.as_ref().and_then(|i| i.size).map(u64::from);
            (&img.source, Some(img.body.clone()), size)
        }
        MessageType::File(f) => {
            let size = f.info.as_ref().and_then(|i| i.size).map(u64::from);
            (
                &f.source,
                f.filename.clone().or_else(|| Some(f.body.clone())),
                size,
            )
        }
        MessageType::Video(v) => {
            let size = v.info.as_ref().and_then(|i| i.size).map(u64::from);
            (&v.source, Some(v.body.clone()), size)
        }
        MessageType::Audio(a) => (&a.source, Some(a.body.clone()), None),
        _ => return (None, None, None, None),
    };
    let mxc_uri = match source {
        MediaSource::Plain(url) => Some(url.to_string()),
        MediaSource::Encrypted(_) => None,
    };
    (mxc_uri, serde_json::to_value(source).ok(), filename, size)
}

fn serialized_media_source_from_content(content: &serde_json::Value) -> Option<serde_json::Value> {
    let source: MediaSource = serde_json::from_value(content.clone()).ok()?;
    serde_json::to_value(source).ok()
}

fn media_download_url(
    homeserver: url::Url,
    uri: &MxcUri,
    endpoint: AuthenticatedMediaEndpoint,
) -> Result<url::Url, Error> {
    let server_name = uri
        .server_name()
        .map_err(|error| Error::IdParse(error.to_string()))?;
    let media_id = uri
        .media_id()
        .map_err(|error| Error::IdParse(error.to_string()))?;
    let mut url = homeserver;
    let mut segments = url
        .path_segments_mut()
        .map_err(|_| Error::Other("homeserver URL cannot be a base URL".into()))?;
    segments.pop_if_empty();
    segments.push("_matrix");
    match endpoint {
        AuthenticatedMediaEndpoint::Stable => {
            segments.push("client");
            segments.push("v1");
            segments.push("media");
        }
        AuthenticatedMediaEndpoint::Unstable => {
            segments.push("client");
            segments.push("unstable");
            segments.push("org.matrix.msc3916");
            segments.push("media");
        }
        AuthenticatedMediaEndpoint::Legacy => {
            segments.push("media");
            segments.push("v3");
        }
    }
    segments.push("download");
    segments.push(server_name.as_str());
    segments.push(media_id);
    drop(segments);
    Ok(url)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AuthenticatedMediaEndpoint {
    Stable,
    Unstable,
    Legacy,
}

impl AuthenticatedMediaEndpoint {
    fn uses_access_token(self) -> bool {
        self != Self::Legacy
    }
}

fn authenticated_media_endpoint(supported: &SupportedVersions) -> AuthenticatedMediaEndpoint {
    if supported
        .versions
        .iter()
        .any(|version| *version >= MatrixVersion::V1_11)
        || supported.features.contains(&FeatureFlag::Msc3916Stable)
    {
        AuthenticatedMediaEndpoint::Stable
    } else if supported.features.contains(&FeatureFlag::Msc3916) {
        AuthenticatedMediaEndpoint::Unstable
    } else {
        AuthenticatedMediaEndpoint::Legacy
    }
}

#[cfg(not(target_family = "wasm"))]
async fn send_bounded_media_request(
    client: &Client,
    url: url::Url,
    authenticated: bool,
) -> Result<matrix_sdk::reqwest::Response, Error> {
    let mut request = client.http_client().get(url);
    if authenticated {
        let token = client
            .access_token()
            .ok_or_else(|| Error::Other("Matrix session has no access token".into()))?;
        request = request.bearer_auth(token);
    }
    request
        .send()
        .await
        .map_err(|error| Error::Other(format!("media download request failed: {error}")))
}

#[cfg(not(target_family = "wasm"))]
async fn download_bounded_media_inner(client: &Client, uri: &MxcUri) -> Result<Vec<u8>, Error> {
    let supported = client.supported_versions().await?;
    let endpoint = authenticated_media_endpoint(&supported);
    let authenticated = endpoint.uses_access_token();
    let url = media_download_url(client.homeserver(), uri, endpoint)?;
    let mut response = send_bounded_media_request(client, url.clone(), authenticated).await?;
    if authenticated && response.status() == matrix_sdk::reqwest::StatusCode::UNAUTHORIZED {
        // Streaming bypasses matrix-sdk's Vec/cache amplification, so retain
        // its single access-token refresh and retry behavior explicitly.
        client
            .matrix_auth()
            .refresh_access_token()
            .await
            .map_err(|error| Error::Other(format!("Matrix refresh token failed: {error}")))?;
        response = send_bounded_media_request(client, url, true).await?;
    }
    if !response.status().is_success() {
        return Err(Error::Other(format!(
            "media download failed with HTTP {}",
            response.status()
        )));
    }
    if let Some(content_length) = response.content_length() {
        let advertised = usize::try_from(content_length).unwrap_or(usize::MAX);
        validate_media_download_size(advertised)?;
    }

    let mut data = Vec::new();
    let mut chunks = response.bytes_stream();
    while let Some(chunk) = chunks.next().await {
        let chunk = chunk
            .map_err(|error| Error::Other(format!("media download stream failed: {error}")))?;
        append_bounded_media_chunk(&mut data, &chunk)?;
    }
    Ok(data)
}

#[cfg(target_family = "wasm")]
struct WebAbortGuard(web_sys::AbortController);

#[cfg(target_family = "wasm")]
impl Drop for WebAbortGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[cfg(target_family = "wasm")]
fn web_media_error(context: &str, error: wasm_bindgen::JsValue) -> Error {
    let detail = error.as_string().unwrap_or_else(|| format!("{error:?}"));
    Error::Other(format!("{context}: {detail}"))
}

#[cfg(target_family = "wasm")]
async fn download_bounded_media_request(
    url: &url::Url,
    access_token: Option<&str>,
) -> Result<(u16, Vec<u8>), Error> {
    use js_sys::{Function, Promise, Reflect, Uint8Array};
    use wasm_bindgen::{JsCast, JsValue};
    use wasm_bindgen_futures::JsFuture;

    let controller = web_sys::AbortController::new()
        .map_err(|error| web_media_error("could not create media abort controller", error))?;
    let abort_guard = WebAbortGuard(controller);
    let init = web_sys::RequestInit::new();
    init.set_method("GET");
    init.set_signal(Some(&abort_guard.0.signal()));
    if let Some(token) = access_token {
        let headers = web_sys::Headers::new()
            .map_err(|error| web_media_error("could not create media headers", error))?;
        headers
            .set("Authorization", &format!("Bearer {token}"))
            .map_err(|error| web_media_error("could not set media authorization", error))?;
        init.set_headers(&headers);
    }
    let request = web_sys::Request::new_with_str_and_init(url.as_str(), &init)
        .map_err(|error| web_media_error("could not create media request", error))?;
    let global = js_sys::global();
    let fetch = Reflect::get(&global, &JsValue::from_str("fetch"))
        .map_err(|error| web_media_error("could not resolve browser fetch", error))?
        .dyn_into::<Function>()
        .map_err(|error| web_media_error("browser fetch is not callable", error))?;
    let promise = fetch
        .call1(&global, request.as_ref())
        .map_err(|error| web_media_error("media fetch failed", error))?
        .dyn_into::<Promise>()
        .map_err(|error| web_media_error("media fetch did not return a promise", error))?;
    let response = JsFuture::from(promise)
        .await
        .map_err(|error| web_media_error("media fetch failed", error))?
        .dyn_into::<web_sys::Response>()
        .map_err(|error| web_media_error("media fetch returned an invalid response", error))?;
    let status = response.status();
    if !(200..300).contains(&status) {
        return Ok((status, Vec::new()));
    }
    if let Some(content_length) = response
        .headers()
        .get("content-length")
        .map_err(|error| web_media_error("could not read media content length", error))?
    {
        if let Ok(advertised) = content_length.parse::<usize>() {
            validate_media_download_size(advertised)?;
        }
    }

    let Some(body) = response.body() else {
        return Ok((status, Vec::new()));
    };
    let reader = web_sys::ReadableStreamDefaultReader::new(&body)
        .map_err(|error| web_media_error("could not read media response stream", error))?;
    let mut data = Vec::new();
    loop {
        let result = JsFuture::from(reader.read())
            .await
            .map_err(|error| web_media_error("media download stream failed", error))?;
        let done = Reflect::get(&result, &JsValue::from_str("done"))
            .map_err(|error| web_media_error("invalid media stream result", error))?
            .as_bool()
            .ok_or_else(|| Error::Other("invalid media stream done flag".into()))?;
        if done {
            break;
        }
        let value = Reflect::get(&result, &JsValue::from_str("value"))
            .map_err(|error| web_media_error("invalid media stream chunk", error))?;
        if !value.is_instance_of::<Uint8Array>() {
            return Err(Error::Other(
                "media response stream returned a non-byte chunk".into(),
            ));
        }
        let chunk = value.unchecked_into::<Uint8Array>();
        let chunk_len = usize::try_from(chunk.length()).unwrap_or(usize::MAX);
        let next_size = bounded_media_next_size(data.len(), chunk_len)?;
        let offset = data.len();
        data.resize(next_size, 0);
        chunk.copy_to(&mut data[offset..]);
    }
    reader.release_lock();
    Ok((status, data))
}

#[cfg(target_family = "wasm")]
async fn download_bounded_media_inner(client: &Client, uri: &MxcUri) -> Result<Vec<u8>, Error> {
    let supported = client.supported_versions().await?;
    let endpoint = authenticated_media_endpoint(&supported);
    let authenticated = endpoint.uses_access_token();
    let url = media_download_url(client.homeserver(), uri, endpoint)?;
    let access_token = if authenticated {
        Some(
            client
                .access_token()
                .ok_or_else(|| Error::Other("Matrix session has no access token".into()))?,
        )
    } else {
        None
    };
    let (mut status, mut data) =
        download_bounded_media_request(&url, access_token.as_deref()).await?;
    if authenticated && status == 401 {
        client
            .matrix_auth()
            .refresh_access_token()
            .await
            .map_err(|error| Error::Other(format!("Matrix refresh token failed: {error}")))?;
        let refreshed_token = client
            .access_token()
            .ok_or_else(|| Error::Other("Matrix session has no access token".into()))?;
        (status, data) =
            download_bounded_media_request(&url, Some(refreshed_token.as_str())).await?;
    }
    if !(200..300).contains(&status) {
        return Err(Error::Other(format!(
            "media download failed with HTTP {status}"
        )));
    }
    Ok(data)
}

#[cfg(not(target_family = "wasm"))]
async fn download_bounded_media(client: &Client, uri: &MxcUri) -> Result<Vec<u8>, Error> {
    tokio::time::timeout(
        Duration::from_secs(50),
        download_bounded_media_inner(client, uri),
    )
    .await
    .map_err(|_| Error::Other("media download timed out after 50 seconds".into()))?
}

#[cfg(target_family = "wasm")]
async fn download_bounded_media(client: &Client, uri: &MxcUri) -> Result<Vec<u8>, Error> {
    use futures_util::future::{select, Either};

    let download = Box::pin(download_bounded_media_inner(client, uri));
    let deadline = Box::pin(gloo_timers::future::TimeoutFuture::new(50_000));
    match select(download, deadline).await {
        Either::Left((result, _)) => result,
        Either::Right(((), _)) => Err(Error::Other(
            "media download timed out after 50 seconds".into(),
        )),
    }
}

#[cfg(any(not(target_family = "wasm"), test))]
fn append_bounded_media_chunk(data: &mut Vec<u8>, chunk: &[u8]) -> Result<(), Error> {
    bounded_media_next_size(data.len(), chunk.len())?;
    data.extend_from_slice(chunk);
    Ok(())
}

fn bounded_media_next_size(current_size: usize, chunk_size: usize) -> Result<usize, Error> {
    let next_size = current_size
        .checked_add(chunk_size)
        .ok_or(Error::MediaTooLarge {
            actual_bytes: usize::MAX,
            max_bytes: MAX_MEDIA_DOWNLOAD_BYTES,
        })?;
    validate_media_download_size(next_size)?;
    Ok(next_size)
}

fn validate_media_download_size(actual_bytes: usize) -> Result<(), Error> {
    if actual_bytes > MAX_MEDIA_DOWNLOAD_BYTES {
        return Err(Error::MediaTooLarge {
            actual_bytes,
            max_bytes: MAX_MEDIA_DOWNLOAD_BYTES,
        });
    }
    Ok(())
}

fn room_message_content_for_display(event: &serde_json::Value) -> Option<&serde_json::Value> {
    if event["type"].as_str()? != "m.room.message" {
        return None;
    }
    let content = event.get("content")?;
    let relates_to = &content["m.relates_to"];
    let replacement = &content["m.new_content"];
    let displayed =
        if relates_to["rel_type"].as_str() == Some("m.replace") && replacement.is_object() {
            replacement
        } else {
            content
        };
    displayed["body"].as_str()?;
    displayed["msgtype"].as_str()?;
    Some(displayed)
}

fn message_event_from_json(event: &serde_json::Value, room_id: &str) -> Option<MessageEvent> {
    let content = &event["content"];
    let relates_to = &content["m.relates_to"];
    let replacement_content = &content["m.new_content"];
    let replaces_event_id = (relates_to["rel_type"].as_str() == Some("m.replace")
        && replacement_content.is_object())
    .then(|| relates_to["event_id"].as_str().map(|s| s.to_owned()))
    .flatten();
    let message_content = match room_message_content_for_display(event) {
        Some(content) => content,
        None if event["unsigned"]["redacted_because"].is_object() => {
            return Some(MessageEvent {
                event_id: event["event_id"].as_str()?.to_owned(),
                room_id: room_id.to_owned(),
                sender: event["sender"].as_str()?.to_owned(),
                body: "Message deleted".into(),
                formatted_body: None,
                msgtype: "m.notice".into(),
                timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
                in_reply_to: None,
                thread_root: None,
                replaces_event_id: None,
                redacts_event_id: None,
                edited_at: None,
                mxc_uri: None,
                media_source: None,
                filename: None,
                file_size: None,
            });
        }
        None => return None,
    };
    let media_source = serialized_media_source_from_content(message_content);
    let mxc_uri = media_source
        .as_ref()
        .and_then(|source| source["url"].as_str())
        .map(str::to_owned);
    let mut message = MessageEvent {
        event_id: event["event_id"].as_str()?.to_owned(),
        room_id: room_id.to_owned(),
        sender: event["sender"].as_str()?.to_owned(),
        body: message_content["body"].as_str()?.to_owned(),
        formatted_body: message_content["formatted_body"]
            .as_str()
            .map(|s| s.to_owned()),
        msgtype: message_content["msgtype"].as_str()?.to_owned(),
        timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
        in_reply_to: (relates_to["is_falling_back"].as_bool() != Some(true))
            .then(|| {
                relates_to["m.in_reply_to"]["event_id"]
                    .as_str()
                    .map(|s| s.to_owned())
            })
            .flatten(),
        thread_root: (relates_to["rel_type"].as_str() == Some("m.thread"))
            .then(|| relates_to["event_id"].as_str().map(|s| s.to_owned()))
            .flatten(),
        replaces_event_id,
        redacts_event_id: None,
        edited_at: None,
        mxc_uri,
        media_source,
        filename: message_content["filename"]
            .as_str()
            .or_else(|| message_content["body"].as_str())
            .map(|s| s.to_owned())
            .and_then(|f| {
                let msgtype = message_content["msgtype"].as_str().unwrap_or_default();
                if ["m.image", "m.file", "m.video", "m.audio"].contains(&msgtype) {
                    Some(f)
                } else {
                    None
                }
            }),
        file_size: message_content["info"]["size"].as_u64(),
    };
    if let Some(replacement) = event.pointer("/unsigned/m.relations/m.replace") {
        if let Some(replacement) = message_event_from_json(replacement, room_id) {
            if replacement.sender == message.sender
                && replacement.replaces_event_id.as_deref() == Some(message.event_id.as_str())
            {
                message.body = replacement.body;
                message.formatted_body = replacement.formatted_body;
                message.msgtype = replacement.msgtype;
                message.edited_at = Some(replacement.timestamp);
                message.mxc_uri = replacement.mxc_uri;
                message.media_source = replacement.media_source;
                message.filename = replacement.filename;
                message.file_size = replacement.file_size;
            }
        }
    }
    Some(message)
}

#[cfg(test)]
fn thread_root_from_event_json(event: &serde_json::Value) -> Option<String> {
    let relation = event.get("content")?.get("m.relates_to")?;
    if relation.get("rel_type")?.as_str()? != "m.thread" {
        return None;
    }
    relation.get("event_id")?.as_str().map(ToOwned::to_owned)
}

fn thread_unread_sync_request() -> ThreadUnreadSyncRequest {
    let mut definition = FilterDefinition::default();
    definition.presence.types = Some(Vec::new());
    definition.account_data.types = Some(Vec::new());
    definition.room.account_data.types = Some(Vec::new());
    definition.room.ephemeral.types = Some(Vec::new());
    definition.room.state.types = Some(Vec::new());
    definition.room.timeline.limit = Some(UInt::from(0_u32));
    definition.room.timeline.unread_thread_notifications = true;
    let mut request = ThreadUnreadSyncRequest::new();
    request.filter = Some(SyncFilter::FilterDefinition(definition));
    // This is a bookkeeping request, not the app's real sync loop: `offline`
    // tells the server to leave the user's presence exactly as it is.
    request.set_presence = matrix_sdk::ruma::presence::PresenceState::Offline;
    // A secondary next_batch must never be stored or reused: doing so would
    // acknowledge unprocessed to-device events on the following request.
    debug_assert!(request.since.is_none());
    request
}

async fn room_thread_index(
    room: Room,
    limit: UInt,
    unread_counts: Option<Arc<HashMap<(String, String), u64>>>,
) -> Result<Vec<ThreadSummary>, Error> {
    let room_id = room.room_id().to_string();
    let room_name = room
        .display_name()
        .await
        .ok()
        .map(|name| name.to_string())
        .unwrap_or_else(|| room_id.clone());
    let mut unresolved_unread = unread_counts
        .as_deref()
        .map(|counts| {
            counts
                .iter()
                .filter(|((candidate_room, _), count)| candidate_room == &room_id && **count > 0)
                .map(|((_, root), _)| root.clone())
                .collect::<HashSet<_>>()
        })
        .unwrap_or_default();
    let mut summaries: Vec<ThreadSummary> = Vec::new();
    let mut from = None;
    let mut first_page = true;
    let mut seen_tokens = HashSet::new();

    loop {
        let page = match room
            .list_threads(ListThreadsOptions {
                from: from.clone(),
                limit: Some(limit),
                ..Default::default()
            })
            .await
        {
            Ok(page) => page,
            // Returning only the first page would silently omit unread roots
            // that the notification aggregate says exist on later pages, so
            // a failure on any page fails the whole index.
            Err(error) => return Err(error.into()),
        };
        for event in &page.chunk {
            let Some(summary) = thread_summary_from_timeline_event(
                event,
                &room_id,
                &room_name,
                unread_counts.as_deref(),
            ) else {
                continue;
            };
            let was_unread = unresolved_unread.remove(&summary.root.event_id);
            if first_page || was_unread {
                summaries.push(summary);
            }
        }

        if unresolved_unread.is_empty() {
            break;
        }
        let Some(next) = page.prev_batch_token else {
            return Err(Error::Other(format!(
                "thread index for {room_id} ended before {} unread roots were found",
                unresolved_unread.len()
            )));
        };
        if !seen_tokens.insert(next.clone()) {
            return Err(Error::Other(format!(
                "thread index for {room_id} repeated a pagination token with {} unread roots unresolved",
                unresolved_unread.len()
            )));
        }
        from = Some(next);
        first_page = false;
    }
    Ok(summaries)
}

fn thread_reply_content(
    body: &str,
    thread_root_event_id: &EventId,
    in_reply_to_event_id: &EventId,
    reply_target_sender: &UserId,
) -> RoomMessageEventContent {
    let explicit_thread = Thread::plain(
        thread_root_event_id.to_owned(),
        in_reply_to_event_id.to_owned(),
    );
    let metadata = ReplyMetadata::new(
        in_reply_to_event_id,
        reply_target_sender,
        Some(&explicit_thread),
    );
    RoomMessageEventContentWithoutRelation::text_plain(body).make_for_thread(
        metadata,
        ReplyWithinThread::Yes,
        AddMentions::Yes,
    )
}

fn thread_summary_from_timeline_event(
    event: &matrix_sdk::deserialized_responses::TimelineEvent,
    room_id: &str,
    room_name: &str,
    unread_counts: Option<&HashMap<(String, String), u64>>,
) -> Option<ThreadSummary> {
    let aggregate = event.thread_summary.summary()?;
    let root_json: serde_json::Value = event.raw().deserialize_as_unchecked().ok()?;
    let root = message_event_from_json(&root_json, room_id)?;
    let latest_reply = event
        .bundled_latest_thread_event
        .as_deref()
        .and_then(|latest| {
            let latest_json: serde_json::Value = latest.raw().deserialize_as_unchecked().ok()?;
            message_event_from_json(&latest_json, room_id)
        });
    let current_user_participated = root_json
        .pointer("/unsigned/m.relations/m.thread/current_user_participated")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let unread_count = unread_counts.map(|counts| {
        counts
            .get(&(room_id.to_owned(), root.event_id.clone()))
            .copied()
            .unwrap_or(0)
    });

    Some(ThreadSummary {
        room_id: room_id.to_owned(),
        room_name: room_name.to_owned(),
        root,
        latest_reply,
        reply_count: aggregate.num_replies,
        unread_count,
        current_user_participated,
    })
}

fn thread_activity_timestamp(thread: &ThreadSummary) -> u64 {
    thread
        .latest_reply
        .as_ref()
        .map(|reply| reply.timestamp)
        .unwrap_or(thread.root.timestamp)
}

/// Matrix returns backward pagination chunks newest-to-oldest. Expose one
/// stable chronological contract to every FFI consumer.
fn chronological_messages_from_backward(mut messages: Vec<MessageEvent>) -> Vec<MessageEvent> {
    messages.reverse();
    messages
}

fn last_message_from_event(event: &serde_json::Value) -> Option<LastMessage> {
    if event["type"].as_str()? == "m.room.message"
        && event["unsigned"]["redacted_because"].is_object()
    {
        return Some(LastMessage {
            sender: event["sender"].as_str()?.to_owned(),
            body: "Message deleted".to_owned(),
            timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
        });
    }
    let content = room_message_content_for_display(event)?;
    Some(LastMessage {
        sender: event["sender"].as_str()?.to_owned(),
        body: content["body"].as_str()?.to_owned(),
        timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
    })
}

fn power_level_field(raw: &serde_json::Value, field: &str, default: i64) -> i64 {
    raw.get(field)
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(default)
}

fn user_power_level(raw: &serde_json::Value, user_id: &str) -> Option<i64> {
    raw.get("users")
        .and_then(|users| users.get(user_id))
        .and_then(serde_json::Value::as_i64)
}

fn power_level_map(raw: &serde_json::Value, field: &str) -> serde_json::Value {
    let Some(map) = raw.get(field).and_then(serde_json::Value::as_object) else {
        return serde_json::json!({});
    };
    serde_json::Value::Object(
        map.iter()
            .filter_map(|(key, value)| {
                value
                    .as_i64()
                    .map(|level| (key.clone(), serde_json::json!(level)))
            })
            .collect(),
    )
}

fn apply_user_power_levels(
    power_levels: &mut RoomPowerLevelsEventContent,
    user_power_levels: Vec<(String, i64)>,
) -> Result<(), Error> {
    for (user_id, power_level) in user_power_levels {
        let user_id = <&UserId>::try_from(user_id.as_str())
            .map_err(|err| Error::IdParse(format!("invalid user ID '{user_id}': {err}")))?;
        let power_level = power_level
            .try_into()
            .map_err(|err| Error::Other(format!("invalid user power level: {err}")))?;
        if power_level == power_levels.users_default {
            power_levels.users.remove(user_id);
        } else {
            power_levels.users.insert(user_id.to_owned(), power_level);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn homeserver_security_requires_https_outside_loopback() {
        assert!(validate_homeserver_security("https://matrix.example.org").is_ok());
        assert!(validate_homeserver_security("http://localhost:8008").is_ok());
        assert!(validate_homeserver_security("http://127.0.0.1:8008").is_ok());
        assert!(validate_homeserver_security("http://[::1]:8008").is_ok());
        assert!(validate_homeserver_security("http://matrix.example.org").is_err());
        assert!(validate_homeserver_security("ftp://matrix.example.org").is_err());
        assert!(validate_homeserver_security("https://user:pass@matrix.example.org").is_err());
        assert!(validate_homeserver_security("https://matrix.example.org?access_token=x").is_err());
        assert!(validate_homeserver_security("https://matrix.example.org/#token").is_err());
        assert_eq!(
            canonical_homeserver_url("HTTPS://Matrix.Example.org/base///").unwrap(),
            "https://matrix.example.org/base"
        );
    }

    #[test]
    fn thread_unread_snapshot_never_advances_an_unprocessed_sync_cursor() {
        let request = thread_unread_sync_request();

        assert!(request.since.is_none());
        assert_eq!(
            request.set_presence,
            matrix_sdk::ruma::presence::PresenceState::Offline
        );
    }

    #[cfg(not(target_family = "wasm"))]
    #[test]
    fn custom_root_certificate_paths_are_validated_before_client_build() {
        let empty_path_error =
            custom_root_certificates_from_paths(&[PathBuf::from("")]).unwrap_err();
        assert!(empty_path_error
            .to_string()
            .contains("custom root certificate path cannot be empty"));

        let missing = std::env::temp_dir().join(format!(
            "manymatrix-missing-ca-{}-{}.pem",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let missing_error = custom_root_certificates_from_paths(&[missing]).unwrap_err();
        assert!(missing_error
            .to_string()
            .contains("could not read custom root certificate"));

        let empty = std::env::temp_dir().join(format!(
            "manymatrix-empty-ca-{}-{}.pem",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        std::fs::write(&empty, []).unwrap();
        let empty_file_error =
            custom_root_certificates_from_paths(std::slice::from_ref(&empty)).unwrap_err();
        let _ = std::fs::remove_file(empty);
        assert!(empty_file_error
            .to_string()
            .contains("custom root certificate file is empty"));
    }

    #[test]
    fn room_message_send_mode_only_probes_unknown_encryption_state() {
        assert_eq!(
            room_message_send_mode(&EncryptionState::Unknown),
            RoomMessageSendMode::ProbeServer
        );
        assert_eq!(
            room_message_send_mode(&EncryptionState::Encrypted),
            RoomMessageSendMode::UseSdk
        );
        assert_eq!(
            room_message_send_mode(&EncryptionState::NotEncrypted),
            RoomMessageSendMode::UseSdk
        );
        assert_eq!(
            send_mode_after_encryption_probe(RoomEncryptionEventPresence::Missing),
            Some(ResolvedRoomMessageSendMode::DirectPlaintext)
        );
        assert_eq!(
            send_mode_after_encryption_probe(RoomEncryptionEventPresence::Present),
            None
        );
    }

    #[test]
    fn non_encrypted_attachments_probe_before_upload() {
        assert_eq!(
            attachment_send_mode(&EncryptionState::Encrypted),
            RoomMessageSendMode::UseSdk
        );
        assert_eq!(
            attachment_send_mode(&EncryptionState::NotEncrypted),
            RoomMessageSendMode::ProbeServer
        );
        assert_eq!(
            attachment_send_mode(&EncryptionState::Unknown),
            RoomMessageSendMode::ProbeServer
        );
        assert_eq!(
            send_mode_after_encryption_probe(RoomEncryptionEventPresence::Present),
            None,
            "a server encryption event must fail before media bytes are uploaded"
        );
    }

    #[test]
    fn plain_attachment_publish_requires_a_second_negative_probe() {
        assert!(can_publish_plain_attachment(
            &EncryptionState::Unknown,
            RoomEncryptionEventPresence::Missing
        ));
        assert!(can_publish_plain_attachment(
            &EncryptionState::NotEncrypted,
            RoomEncryptionEventPresence::Missing
        ));
        assert!(!can_publish_plain_attachment(
            &EncryptionState::Unknown,
            RoomEncryptionEventPresence::Present
        ));
        assert!(!can_publish_plain_attachment(
            &EncryptionState::Encrypted,
            RoomEncryptionEventPresence::Missing
        ));
    }

    #[test]
    fn plaintext_message_request_preserves_message_content_and_transaction_id() {
        let room_id = <&RoomId>::try_from("!send-test:example.org")
            .unwrap()
            .to_owned();
        let transaction_id: OwnedTransactionId = "manymatrix-send-test".into();
        let content = RoomMessageEventContent::text_plain("hello from ManyMatrix");

        let request =
            plaintext_message_request(room_id.clone(), transaction_id.clone(), &content).unwrap();
        let body: serde_json::Value = serde_json::from_str(request.body.json().get()).unwrap();

        assert_eq!(request.room_id, room_id);
        assert_eq!(request.txn_id, transaction_id);
        assert_eq!(request.event_type.to_string(), "m.room.message");
        assert_eq!(body["msgtype"], "m.text");
        assert_eq!(body["body"], "hello from ManyMatrix");
    }

    #[test]
    fn newer_direct_send_preview_wins_until_sdk_catches_up() {
        let synced = LastMessageCandidate {
            event_id: Some("$older".to_owned()),
            message: LastMessage {
                sender: "@alice:example.org".to_owned(),
                body: "older SDK message".to_owned(),
                timestamp: 100,
            },
        };
        let optimistic = outbound_last_message_candidate(
            "$direct".to_owned(),
            "@alice:example.org".to_owned(),
            &RoomMessageEventContent::text_plain("new direct message"),
            200,
        )
        .unwrap();

        let (selected, evict) = merge_last_message_candidates(Some(&synced), Some(&optimistic));
        assert_eq!(selected.unwrap().body, "new direct message");
        assert!(!evict);

        let caught_up = LastMessageCandidate {
            event_id: optimistic.event_id.clone(),
            message: LastMessage {
                sender: "@alice:example.org".to_owned(),
                body: "new direct message".to_owned(),
                timestamp: 150,
            },
        };
        let (selected, evict) = merge_last_message_candidates(Some(&caught_up), Some(&optimistic));
        assert_eq!(selected.unwrap().body, "new direct message");
        assert!(evict);
    }

    #[test]
    fn plaintext_raw_message_request_preserves_custom_event_shape() {
        let room_id = <&RoomId>::try_from("!custom-send:example.org")
            .unwrap()
            .to_owned();
        let transaction_id: OwnedTransactionId = "manymatrix-custom-test".into();
        let content = serde_json::json!({
            "operation": "advance",
            "position": {"row": 4, "column": 7}
        });

        let request = plaintext_raw_message_request(
            room_id.clone(),
            transaction_id.clone(),
            "io.manymath.playback",
            &content,
        )
        .unwrap();
        let body: serde_json::Value = serde_json::from_str(request.body.json().get()).unwrap();

        assert_eq!(request.room_id, room_id);
        assert_eq!(request.txn_id, transaction_id);
        assert_eq!(request.event_type.to_string(), "io.manymath.playback");
        assert_eq!(body, content);
    }

    #[test]
    fn plain_attachment_content_matches_matrix_mime_families() {
        let cases = [
            ("image/png; profile=example", "m.image"),
            ("audio/mpeg", "m.audio"),
            ("video/mp4", "m.video"),
            ("application/pdf", "m.file"),
        ];

        for (mime_type, expected_msgtype) in cases {
            let mime: mime::Mime = mime_type.parse().unwrap();
            let content_uri = <&MxcUri>::from("mxc://media.example.org/uploaded").to_owned();
            let content = plain_attachment_content("proof.bin", &mime, content_uri, 42);
            let body = serde_json::to_value(content).unwrap();

            assert_eq!(body["msgtype"], expected_msgtype, "{mime_type}");
            assert_eq!(body["body"], "proof.bin", "{mime_type}");
            assert_eq!(body["info"]["mimetype"], mime.as_ref(), "{mime_type}");
            assert_eq!(body["info"]["size"], 42, "{mime_type}");
            assert_eq!(
                body["url"], "mxc://media.example.org/uploaded",
                "{mime_type}"
            );
            assert!(body.get("filename").is_none(), "{mime_type}");
            assert!(body.get("file").is_none(), "{mime_type}");
        }
    }

    #[test]
    fn plain_media_source_rejects_malformed_mxc_uris() {
        for bad in [
            "https://example.org/file",
            "mxc://",
            "mxc://example.org",
            "not a uri",
        ] {
            let error = plain_media_source_from_mxc(bad).unwrap_err();
            assert!(
                matches!(error, Error::IdParse(_)),
                "{bad:?} should be rejected as an ID parse error, got {error:?}"
            );
        }
    }

    #[test]
    fn media_download_urls_preserve_homeserver_prefix_and_endpoint_version() {
        let source = plain_media_source_from_mxc("mxc://media.example.org/media-123").unwrap();
        let MediaSource::Plain(uri) = source else {
            unreachable!()
        };
        let homeserver = url::Url::parse("https://matrix.example.org/prefix").unwrap();

        assert_eq!(
            media_download_url(homeserver.clone(), &uri, AuthenticatedMediaEndpoint::Stable,)
                .unwrap()
                .as_str(),
            "https://matrix.example.org/prefix/_matrix/client/v1/media/download/media.example.org/media-123"
        );
        assert_eq!(
            media_download_url(
                homeserver.clone(),
                &uri,
                AuthenticatedMediaEndpoint::Unstable,
            )
            .unwrap()
            .as_str(),
            "https://matrix.example.org/prefix/_matrix/client/unstable/org.matrix.msc3916/media/download/media.example.org/media-123"
        );
        assert_eq!(
            media_download_url(homeserver, &uri, AuthenticatedMediaEndpoint::Legacy)
                .unwrap()
                .as_str(),
            "https://matrix.example.org/prefix/_matrix/media/v3/download/media.example.org/media-123"
        );
    }

    #[test]
    fn authenticated_media_endpoint_honors_stable_and_unstable_features() {
        use std::collections::BTreeMap;

        let support = |version: &str, feature: Option<&str>| {
            let mut features = BTreeMap::new();
            if let Some(feature) = feature {
                features.insert(feature.to_owned(), true);
            }
            SupportedVersions::from_parts(&[version.to_owned()], &features)
        };

        assert_eq!(
            authenticated_media_endpoint(&support("v1.11", None)),
            AuthenticatedMediaEndpoint::Stable
        );
        assert_eq!(
            authenticated_media_endpoint(&support("v1.10", Some("org.matrix.msc3916.stable"))),
            AuthenticatedMediaEndpoint::Stable
        );
        assert_eq!(
            authenticated_media_endpoint(&support("v1.10", Some("org.matrix.msc3916"))),
            AuthenticatedMediaEndpoint::Unstable
        );
        assert_eq!(
            authenticated_media_endpoint(&support("v1.10", None)),
            AuthenticatedMediaEndpoint::Legacy
        );
    }

    #[test]
    fn encrypted_media_source_retains_its_decryption_descriptor() {
        let content = serde_json::json!({
            "msgtype": "m.file",
            "body": "secret.txt",
            "file": {
                "url": "mxc://matrix.example.org/encrypted",
                "key": {
                    "kty": "oct",
                    "key_ops": ["encrypt", "decrypt"],
                    "alg": "A256CTR",
                    "k": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    "ext": true
                },
                "iv": "AAAAAAAAAAAAAAAAAAAAAA",
                "hashes": {
                    "sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                "v": "v2"
            }
        });

        let source = serialized_media_source_from_content(&content).expect("media source");

        assert_eq!(source["file"]["url"], "mxc://matrix.example.org/encrypted");
        assert_eq!(source["file"]["v"], "v2");
        assert!(source["file"]["key"]["k"].is_string());
        assert!(source["file"]["hashes"]["sha256"].is_string());
    }

    #[test]
    fn timeline_display_filters_state_and_malformed_message_events() {
        let state_event = serde_json::json!({
            "type": "m.room.member",
            "content": {"membership": "join"}
        });
        let malformed_message = serde_json::json!({
            "type": "m.room.message",
            "content": {"msgtype": "m.text"}
        });
        let text_message = serde_json::json!({
            "type": "m.room.message",
            "sender": "@alice:example.org",
            "origin_server_ts": 42,
            "content": {"msgtype": "m.text", "body": "hello"}
        });
        let reaction = serde_json::json!({
            "type": "m.reaction",
            "sender": "@bob:example.org",
            "origin_server_ts": 43,
            "content": {"m.relates_to": {"event_id": "$message", "key": "ok"}}
        });
        let redaction = serde_json::json!({
            "type": "m.room.redaction",
            "sender": "@alice:example.org",
            "origin_server_ts": 44,
            "redacts": "$message",
            "content": {}
        });
        let redacted_message = serde_json::json!({
            "type": "m.room.message",
            "sender": "@alice:example.org",
            "origin_server_ts": 44,
            "content": {},
            "unsigned": {
                "redacted_because": {
                    "type": "m.room.redaction",
                    "sender": "@alice:example.org",
                    "redacts": "$message",
                    "content": {}
                }
            }
        });
        let replacement = serde_json::json!({
            "type": "m.room.message",
            "sender": "@alice:example.org",
            "origin_server_ts": 45,
            "content": {
                "msgtype": "m.text",
                "body": "* stale fallback",
                "m.relates_to": {"rel_type": "m.replace", "event_id": "$message"},
                "m.new_content": {"msgtype": "m.text", "body": "edited preview"}
            }
        });

        assert!(room_message_content_for_display(&state_event).is_none());
        assert!(room_message_content_for_display(&malformed_message).is_none());
        assert_eq!(
            room_message_content_for_display(&text_message).unwrap()["body"],
            "hello"
        );
        assert_eq!(
            last_message_from_event(&text_message).unwrap().body,
            "hello"
        );
        assert!(last_message_from_event(&reaction).is_none());
        assert!(last_message_from_event(&redaction).is_none());
        let deleted = last_message_from_event(&redacted_message).unwrap();
        assert_eq!(deleted.body, "Message deleted");
        assert_eq!(deleted.timestamp, 44);
        assert_eq!(
            last_message_from_event(&replacement).unwrap().body,
            "edited preview"
        );
    }

    #[test]
    fn backward_message_chunks_are_exposed_in_chronological_order() {
        let server_order = [
            serde_json::json!({
                "event_id": "$edit",
                "type": "m.room.message",
                "sender": "@alice:example.org",
                "origin_server_ts": 3,
                "content": {
                    "msgtype": "m.text",
                    "body": "* stale fallback",
                    "m.relates_to": {
                        "rel_type": "m.replace",
                        "event_id": "$original"
                    },
                    "m.new_content": {"msgtype": "m.text", "body": "edited"}
                }
            }),
            serde_json::json!({
                "event_id": "$second",
                "type": "m.room.message",
                "sender": "@bob:example.org",
                "origin_server_ts": 2,
                "content": {"msgtype": "m.text", "body": "second"}
            }),
            serde_json::json!({
                "event_id": "$original",
                "type": "m.room.message",
                "sender": "@alice:example.org",
                "origin_server_ts": 1,
                "content": {"msgtype": "m.text", "body": "original"}
            }),
        ];

        let messages = chronological_messages_from_backward(
            server_order
                .iter()
                .filter_map(|event| message_event_from_json(event, "!room:example.org"))
                .collect(),
        );

        assert_eq!(
            messages
                .iter()
                .map(|message| message.event_id.as_str())
                .collect::<Vec<_>>(),
            ["$original", "$second", "$edit"]
        );
        assert_eq!(
            messages
                .iter()
                .map(|message| message.timestamp)
                .collect::<Vec<_>>(),
            [1, 2, 3]
        );
        assert_eq!(messages[2].replaces_event_id.as_deref(), Some("$original"));
        assert_eq!(messages[2].body, "edited");
    }

    #[test]
    fn bundled_replacement_requires_the_original_sender() {
        let event = serde_json::json!({
            "type": "m.room.message",
            "event_id": "$root",
            "sender": "@alice:example.org",
            "origin_server_ts": 100,
            "content": {"msgtype": "m.text", "body": "Original"},
            "unsigned": {"m.relations": {"m.replace": {
                "type": "m.room.message",
                "event_id": "$edit",
                "sender": "@alice:example.org",
                "origin_server_ts": 200,
                "content": {
                    "msgtype": "m.text",
                    "body": "* stale fallback",
                    "m.relates_to": {"rel_type": "m.replace", "event_id": "$root"},
                    "m.new_content": {"msgtype": "m.text", "body": "Edited"}
                }
            }}}
        });

        let edited = message_event_from_json(&event, "!room:example.org").unwrap();
        assert_eq!(edited.body, "Edited");
        assert_eq!(edited.edited_at, Some(200));

        let mut foreign = event;
        foreign["unsigned"]["m.relations"]["m.replace"]["sender"] =
            serde_json::json!("@mallory:example.org");
        let unchanged = message_event_from_json(&foreign, "!room:example.org").unwrap();
        assert_eq!(unchanged.body, "Original");
        assert_eq!(unchanged.edited_at, None);
    }

    #[test]
    fn thread_summary_uses_server_aggregate_and_unread_notifications() {
        let raw = Raw::<matrix_sdk::ruma::events::AnySyncTimelineEvent>::from_json_string(
            serde_json::json!({
                "type": "m.room.message",
                "event_id": "$root",
                "sender": "@alice:example.org",
                "origin_server_ts": 100,
                "content": {"msgtype": "m.text", "body": "Design review"},
                "unsigned": {
                    "m.relations": {
                        "m.thread": {
                            "count": 3,
                            "current_user_participated": true,
                            "latest_event": {
                                "type": "m.room.message",
                                "event_id": "$latest",
                                "sender": "@bob:example.org",
                                "origin_server_ts": 250,
                                "content": {
                                    "msgtype": "m.text",
                                    "body": "Latest reply",
                                    "m.relates_to": {
                                        "rel_type": "m.thread",
                                        "event_id": "$root"
                                    }
                                }
                            }
                        }
                    }
                }
            })
            .to_string(),
        )
        .unwrap();
        let event = matrix_sdk::deserialized_responses::TimelineEvent::from_plaintext(raw);
        let unread = HashMap::from([(("!room:example.org".into(), "$root".into()), 2)]);

        let summary = thread_summary_from_timeline_event(
            &event,
            "!room:example.org",
            "Product",
            Some(&unread),
        )
        .unwrap();

        assert_eq!(summary.reply_count, 3);
        assert_eq!(summary.unread_count, Some(2));
        assert!(summary.current_user_participated);
        assert_eq!(summary.latest_reply.as_ref().unwrap().event_id, "$latest");
        assert_eq!(thread_activity_timestamp(&summary), 250);
    }

    #[test]
    fn thread_summary_preserves_unknown_unread_state() {
        let raw = Raw::<matrix_sdk::ruma::events::AnySyncTimelineEvent>::from_json_string(
            serde_json::json!({
                "type": "m.room.message",
                "event_id": "$root",
                "sender": "@alice:example.org",
                "origin_server_ts": 100,
                "content": {"msgtype": "m.text", "body": "Root"},
                "unsigned": {"m.relations": {"m.thread": {
                    "count": 1,
                    "current_user_participated": false,
                    "latest_event": {
                        "type": "m.room.message",
                        "event_id": "$reply",
                        "sender": "@bob:example.org",
                        "origin_server_ts": 200,
                        "content": {"msgtype": "m.text", "body": "Reply", "m.relates_to": {
                            "rel_type": "m.thread", "event_id": "$root"
                        }}
                    }
                }}}
            })
            .to_string(),
        )
        .unwrap();
        let event = matrix_sdk::deserialized_responses::TimelineEvent::from_plaintext(raw);
        let summary =
            thread_summary_from_timeline_event(&event, "!room:example.org", "Product", None)
                .unwrap();
        assert_eq!(summary.unread_count, None);
    }

    #[test]
    fn thread_summary_keeps_a_redacted_root_as_a_tombstone() {
        let raw = Raw::<matrix_sdk::ruma::events::AnySyncTimelineEvent>::from_json_string(
            serde_json::json!({
                "type": "m.room.message",
                "event_id": "$root",
                "sender": "@alice:example.org",
                "origin_server_ts": 100,
                "content": {},
                "unsigned": {
                    "redacted_because": {
                        "type": "m.room.redaction",
                        "event_id": "$redaction",
                        "sender": "@alice:example.org",
                        "origin_server_ts": 300,
                        "redacts": "$root",
                        "content": {}
                    },
                    "m.relations": {"m.thread": {
                        "count": 1,
                        "current_user_participated": false,
                        "latest_event": {
                            "type": "m.room.message",
                            "event_id": "$reply",
                            "sender": "@bob:example.org",
                            "origin_server_ts": 200,
                            "content": {"msgtype": "m.text", "body": "Reply", "m.relates_to": {
                                "rel_type": "m.thread", "event_id": "$root"
                            }}
                        }
                    }}
                }
            })
            .to_string(),
        )
        .unwrap();
        let event = matrix_sdk::deserialized_responses::TimelineEvent::from_plaintext(raw);

        let summary =
            thread_summary_from_timeline_event(&event, "!room:example.org", "Product", None)
                .unwrap();

        assert_eq!(summary.root.body, "Message deleted");
        assert_eq!(summary.reply_count, 1);
        assert_eq!(summary.latest_reply.unwrap().event_id, "$reply");
    }

    #[test]
    fn thread_root_detection_supports_clear_relation_metadata() {
        let event = serde_json::json!({
            "type": "m.room.encrypted",
            "content": {
                "algorithm": "m.megolm.v1.aes-sha2",
                "ciphertext": "opaque",
                "m.relates_to": {
                    "rel_type": "m.thread",
                    "event_id": "$root"
                }
            }
        });
        assert_eq!(
            thread_root_from_event_json(&event).as_deref(),
            Some("$root")
        );
        assert!(thread_root_from_event_json(&serde_json::json!({
            "content": {"m.relates_to": {"rel_type": "m.annotation", "event_id": "$root"}}
        }))
        .is_none());
    }

    #[test]
    fn threaded_reply_content_keeps_root_and_selected_reply_target_distinct() {
        let root = <&EventId>::try_from("$root:example.org").unwrap();
        let nested = <&EventId>::try_from("$nested:example.org").unwrap();
        let sender = <&UserId>::try_from("@bob:example.org").unwrap();

        for (target, expected_target) in [(root, root.as_str()), (nested, nested.as_str())] {
            let content = thread_reply_content("Answer", root, target, sender);
            let json = serde_json::to_value(content).unwrap();
            assert_eq!(json["m.relates_to"]["rel_type"], "m.thread");
            assert_eq!(json["m.relates_to"]["event_id"], root.as_str());
            assert_eq!(
                json["m.relates_to"]["m.in_reply_to"]["event_id"],
                expected_target
            );
            assert_ne!(json["m.relates_to"]["is_falling_back"], true);
        }
    }

    #[test]
    fn paginated_thread_replies_only_report_explicit_reply_targets() {
        let event = |relates_to: serde_json::Value| {
            serde_json::json!({
                "event_id": "$reply:example.org",
                "sender": "@bob:example.org",
                "type": "m.room.message",
                "origin_server_ts": 1,
                "content": {
                    "msgtype": "m.text",
                    "body": "Answer",
                    "m.relates_to": relates_to,
                },
            })
        };

        let explicit = message_event_from_json(
            &event(serde_json::json!({
                "rel_type": "m.thread",
                "event_id": "$root:example.org",
                "m.in_reply_to": {"event_id": "$nested:example.org"},
            })),
            "!room:example.org",
        )
        .unwrap();
        assert_eq!(explicit.thread_root.as_deref(), Some("$root:example.org"));
        assert_eq!(explicit.in_reply_to.as_deref(), Some("$nested:example.org"));

        let fallback = message_event_from_json(
            &event(serde_json::json!({
                "rel_type": "m.thread",
                "event_id": "$root:example.org",
                "m.in_reply_to": {"event_id": "$latest:example.org"},
                "is_falling_back": true,
            })),
            "!room:example.org",
        )
        .unwrap();
        assert_eq!(fallback.thread_root.as_deref(), Some("$root:example.org"));
        assert_eq!(fallback.in_reply_to, None);
    }

    #[test]
    fn media_downloads_have_a_hard_memory_limit() {
        assert!(validate_media_download_size(MAX_MEDIA_DOWNLOAD_BYTES).is_ok());
        let error = validate_media_download_size(MAX_MEDIA_DOWNLOAD_BYTES + 1).unwrap_err();
        assert!(matches!(error, Error::MediaTooLarge { .. }));
        assert_eq!(error.details()["reason"], "media_too_large");

        let mut bytes = vec![0; MAX_MEDIA_DOWNLOAD_BYTES - 2];
        append_bounded_media_chunk(&mut bytes, &[1, 2]).unwrap();
        assert_eq!(bytes.len(), MAX_MEDIA_DOWNLOAD_BYTES);
        let error = append_bounded_media_chunk(&mut bytes, &[3]).unwrap_err();
        assert!(matches!(error, Error::MediaTooLarge { .. }));
        assert_eq!(bytes.len(), MAX_MEDIA_DOWNLOAD_BYTES);
    }

    #[test]
    fn create_room_request_uses_private_chat_preset_for_private_visibility() {
        let request = create_room_request_from_options(CreateRoomOptions {
            name: Some("Private session".to_owned()),
            topic: None,
            invite: vec![],
            visibility: RoomVisibility::Private,
        })
        .expect("request");

        assert_eq!(request.visibility, Visibility::Private);
        assert_eq!(request.preset, Some(RoomPreset::PrivateChat));
    }

    #[test]
    fn create_room_request_uses_public_chat_preset_for_public_visibility() {
        let request = create_room_request_from_options(CreateRoomOptions {
            name: Some("Public session".to_owned()),
            topic: None,
            invite: vec![],
            visibility: RoomVisibility::Public,
        })
        .expect("request");

        assert_eq!(request.visibility, Visibility::Public);
        assert_eq!(request.preset, Some(RoomPreset::PublicChat));
    }

    #[test]
    fn room_power_level_helpers_apply_matrix_defaults() {
        let raw = serde_json::json!({
            "invite": 50,
            "users": {"@alice:local": 100},
            "events": {"io.manymath.playback": 50}
        });

        assert_eq!(power_level_field(&raw, "invite", 0), 50);
        assert_eq!(power_level_field(&raw, "kick", 50), 50);
        assert_eq!(power_level_field(&raw, "users_default", 0), 0);
        assert_eq!(user_power_level(&raw, "@alice:local"), Some(100));
        assert_eq!(user_power_level(&raw, "@bob:local"), None);
        assert_eq!(
            power_level_map(&raw, "events"),
            serde_json::json!({"io.manymath.playback": 50})
        );
    }
}

#[cfg(target_family = "wasm")]
impl ManyMatrixClient {
    /// Build a new client pointing at `homeserver_url`, storing state in the
    /// IndexedDB database named `store_name`.
    pub async fn new(homeserver_url: &str, store_name: &str) -> Result<Self, Error> {
        validate_homeserver_security(homeserver_url)?;
        let homeserver = canonical_homeserver_url(homeserver_url)?;
        let mut holder_random = [0_u8; 16];
        getrandom::fill(&mut holder_random)
            .map_err(|error| Error::Other(format!("could not create store lock owner: {error}")))?;
        let holder_name = holder_random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let client = Client::builder()
            .homeserver_url(&homeserver)
            .indexeddb_store(store_name, None)
            .cross_process_store_locks_holder_name(format!("manymatrix-{holder_name}"))
            .handle_refresh_tokens()
            .with_encryption_settings(key_backup_encryption_settings())
            .build()
            .await?;
        let latest_session_json = Arc::new(StdMutex::new(None));
        let session_update_callback = Arc::new(StdMutex::new(None));
        {
            let homeserver = homeserver.clone();
            let latest_session_json = latest_session_json.clone();
            let session_update_callback = session_update_callback.clone();
            client.set_session_callbacks(
                Box::new(|client| {
                    client.session_tokens().ok_or_else(
                        || -> Box<dyn std::error::Error + Send + Sync> {
                            "no active Matrix session tokens".into()
                        },
                    )
                }),
                Box::new(move |client| {
                    let session = client.matrix_auth().session().ok_or_else(
                        || -> Box<dyn std::error::Error + Send + Sync> {
                            "no active Matrix session".into()
                        },
                    )?;
                    let stored = StoredSession {
                        homeserver: homeserver.clone(),
                        session,
                    };
                    ManyMatrixClient::publish_session_json(
                        &latest_session_json,
                        &session_update_callback,
                        &stored,
                    )
                    // matrix-sdk's wasm error contains a non-Send boxed
                    // browser error. Session callbacks require a Send + Sync
                    // error even though they execute on the worker's single
                    // thread, so preserve the diagnostic as an owned string.
                    .map_err(
                        |error| -> Box<dyn std::error::Error + Send + Sync> {
                            error.to_string().into()
                        },
                    )
                }),
            )?;
        }
        info!("WASM client built for {}", homeserver);
        Ok(Self {
            client,
            homeserver,
            sync_token: Arc::new(Mutex::new(None)),
            sync_guard: Arc::new(Mutex::new(())),
            latest_session_json,
            session_update_callback,
            session_revoked: Arc::new(AtomicBool::new(false)),
            sync_logging_attached: Arc::new(AtomicBool::new(false)),
            optimistic_last_messages: Arc::new(StdMutex::new(HashMap::new())),
            thread_unread_cache: Arc::new(Mutex::new(ThreadUnreadCache::default())),
            store_path: PathBuf::from(store_name),
        })
    }
}
