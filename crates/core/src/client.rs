use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

use matrix_sdk::attachment::AttachmentConfig;
use matrix_sdk::config::SyncSettings;
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::api::client::room::create_room::v3::Request as CreateRoomRequest;
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::events::reaction::ReactionEventContent;
use matrix_sdk::ruma::events::receipt::ReceiptThread;
use matrix_sdk::ruma::events::relation::Annotation;
use matrix_sdk::ruma::events::room::message::{
    AddMentions, ForwardThread, ReplyWithinThread, RoomMessageEventContent,
    RoomMessageEventContentWithoutRelation, SyncRoomMessageEvent,
};
use matrix_sdk::ruma::events::room::MediaSource;
use matrix_sdk::ruma::events::{AnyMessageLikeEvent, AnyTimelineEvent, MessageLikeEvent};
use matrix_sdk::ruma::{EventId, MxcUri, RoomId, RoomOrAliasId, UInt, UserId};
use matrix_sdk::{Client, Room, RoomMemberships};
use tracing::info;

use crate::session::StoredSession;
use crate::types::{
    CreateRoomOptions, LastMessage, MessageEvent, PaginatedMessages, RoomSummary, RoomVisibility,
    ServerCapabilities,
};
use crate::Error;

#[cfg(not(target_family = "wasm"))]
use {
    std::path::Path,
    matrix_sdk::ruma::events::receipt::ReceiptEventContent,
    matrix_sdk::ruma::events::{OriginalSyncMessageLikeEvent, SyncEphemeralRoomEvent},
    matrix_sdk::ruma::DeviceId,
    crate::types::{ReactionEvent, ReceiptEvent, SasEmoji, SasEmojis},
};

/// High-level Matrix client wrapping [`matrix_sdk::Client`].
#[derive(Clone)]
pub struct ManyMatrixClient {
    client: Client,
    homeserver: String,
    store_path: PathBuf,
    sync_token: Arc<Mutex<Option<String>>>,
}

impl ManyMatrixClient {
    /// Login with username and password.
    pub async fn login(&self, username: &str, password: &str) -> Result<StoredSession, Error> {
        self.client
            .matrix_auth()
            .login_username(username, password)
            .initial_device_display_name("matrix-rust-client")
            .request_refresh_token()
            .send()
            .await?;

        let session = self
            .client
            .matrix_auth()
            .session()
            .ok_or_else(|| Error::Other("no session after login".into()))?;

        let stored = StoredSession {
            homeserver: self.homeserver.clone(),
            session,
        };
        Ok(stored)
    }

    /// Restore a previously saved session.
    pub async fn restore(&self, session: &StoredSession) -> Result<(), Error> {
        self.client.restore_session(session.session.clone()).await?;
        Ok(())
    }

    /// Log out of the homeserver and remove local state.
    pub async fn logout(&self) -> Result<(), Error> {
        // 1. Server-side: invalidate token (do this first)
        let server_result = self.client.matrix_auth().logout().await;

        // 2. Delete entire store directory (crypto keys + state).
        // On wasm the store is IndexedDB, not a directory, this is a no-op there.
        let _ = std::fs::remove_dir_all(&self.store_path);

        // If server-side failed, return the error after local cleanup
        server_result?;
        Ok(())
    }

    /// Run the sync loop, printing incoming messages to the log.
    /// Runs until an error occurs.
    pub async fn sync_forever(&self) -> Result<(), Error> {
        // Register a handler for incoming room messages.
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

        info!("starting sync...");
        self.client.sync(SyncSettings::default()).await?;
        Ok(())
    }

    /// Single sync round. Tracks the sync token for incremental syncs.
    pub async fn sync_once(&self) -> Result<(), Error> {
        self.sync_once_with_timeout_inner(None).await
    }

    /// Single sync round with an explicit long-poll timeout.
    pub async fn sync_once_with_timeout(&self, timeout: Duration) -> Result<(), Error> {
        self.sync_once_with_timeout_inner(Some(timeout)).await
    }

    async fn sync_once_with_timeout_inner(&self, timeout: Option<Duration>) -> Result<(), Error> {
        let mut settings = SyncSettings::default();
        if let Some(timeout) = timeout {
            settings = settings.timeout(timeout);
        }
        if let Some(ref token) = *self.sync_token.lock().await {
            settings = settings.token(token.clone());
        }
        let response = self.client.sync_once(settings).await?;
        *self.sync_token.lock().await = Some(response.next_batch);
        Ok(())
    }

    /// Escape hatch: access the underlying [`matrix_sdk::Client`].
    pub fn inner(&self) -> &Client {
        &self.client
    }

    /// Whether a session is currently active.
    pub fn logged_in(&self) -> bool {
        self.client.matrix_auth().session().is_some()
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
        let resp = room.send(content).await?;
        Ok(resp.event_id.to_string())
    }

    /// List joined rooms.
    pub async fn joined_rooms(&self) -> Vec<RoomSummary> {
        let mut summaries = Vec::new();
        for room in self.client.joined_rooms() {
            let room_id = room.room_id().to_string();
            let display_name = room
                .display_name()
                .await
                .ok()
                .map(|n| n.to_string())
                .unwrap_or_else(|| room_id.clone());
            let avatar_url = room.avatar_url().map(|u| u.to_string());
            let unread = room.unread_notification_counts();

            // Fetch latest message via backward pagination (limit 1)
            let last_message = {
                let mut options = MessagesOptions::backward();
                options.limit = UInt::from(1u32);
                match room.messages(options).await {
                    Ok(response) => {
                        response.chunk.first().and_then(|timeline_event| {
                            let event: serde_json::Value =
                                timeline_event.raw().deserialize_as_unchecked().ok()?;
                            // Only extract from m.room.message events
                            let msgtype = event["content"]["msgtype"].as_str()?;
                            if msgtype.starts_with("m.") {
                                Some(LastMessage {
                                    sender: event["sender"].as_str()?.to_owned(),
                                    body: event["content"]["body"]
                                        .as_str()
                                        .unwrap_or_default()
                                        .to_owned(),
                                    timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
                                })
                            } else {
                                None
                            }
                        })
                    }
                    Err(_) => None,
                }
            };

            summaries.push(RoomSummary {
                room_id,
                display_name,
                avatar_url,
                last_message,
                unread_count: unread.notification_count,
            });
        }
        summaries
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

        let messages: Vec<MessageEvent> = response
            .chunk
            .iter()
            .filter_map(|timeline_event| {
                let event: serde_json::Value =
                    timeline_event.raw().deserialize_as_unchecked().ok()?;
                Some(MessageEvent {
                    event_id: event["event_id"].as_str()?.to_owned(),
                    room_id: room_id.to_owned(),
                    sender: event["sender"].as_str()?.to_owned(),
                    body: event["content"]["body"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                    formatted_body: event["content"]["formatted_body"]
                        .as_str()
                        .map(|s| s.to_owned()),
                    msgtype: event["content"]["msgtype"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                    timestamp: event["origin_server_ts"].as_u64().unwrap_or(0),
                    in_reply_to: event["content"]["m.relates_to"]["m.in_reply_to"]["event_id"]
                        .as_str()
                        .map(|s| s.to_owned()),
                    thread_root: event["content"]["m.relates_to"]["event_id"]
                        .as_str()
                        .map(|s| s.to_owned()),
                    mxc_uri: event["content"]["url"].as_str().map(|s| s.to_owned()),
                    filename: event["content"]["filename"]
                        .as_str()
                        .or_else(|| event["content"]["body"].as_str())
                        .map(|s| s.to_owned())
                        .and_then(|f| {
                            let msgtype = event["content"]["msgtype"].as_str().unwrap_or_default();
                            if ["m.image", "m.file", "m.video", "m.audio"].contains(&msgtype) {
                                Some(f)
                            } else {
                                None
                            }
                        }),
                    file_size: event["content"]["info"]["size"].as_u64(),
                })
            })
            .collect();

        let end_token = response.end;
        Ok(PaginatedMessages {
            messages,
            end_token,
        })
    }

    /// Create a new room with the given options.
    pub async fn create_room(&self, options: CreateRoomOptions) -> Result<String, Error> {
        let mut request = CreateRoomRequest::new();
        request.name = options.name;
        request.topic = options.topic;

        // Parse invite user IDs from strings
        request.invite = options
            .invite
            .iter()
            .map(|id| {
                <&UserId>::try_from(id.as_str())
                    .map(|u| u.to_owned())
                    .map_err(|e| Error::Other(format!("invalid user ID '{}': {}", id, e)))
            })
            .collect::<Result<Vec<_>, _>>()?;

        request.visibility = match options.visibility {
            RoomVisibility::Public => Visibility::Public,
            RoomVisibility::Private => Visibility::Private,
        };

        let room = self.client.create_room(request).await?;
        Ok(room.room_id().to_string())
    }

    /// Join a room by ID or alias.
    pub async fn join_room(&self, room_id_or_alias: &str) -> Result<String, Error> {
        let room = if room_id_or_alias.starts_with('!') {
            let room_id = <&RoomId>::try_from(room_id_or_alias)
                .map_err(|e| Error::Other(format!("invalid room ID: {e}")))?;
            self.client.join_room_by_id(room_id).await?
        } else {
            let alias = <&RoomOrAliasId>::try_from(room_id_or_alias)
                .map_err(|e| Error::Other(format!("invalid room alias: {e}")))?;
            self.client.join_room_by_id_or_alias(alias, &[]).await?
        };
        Ok(room.room_id().to_string())
    }

    /// Invite a user to a room.
    pub async fn invite(&self, room_id: &str, user_id: &str) -> Result<(), Error> {
        let room_id = <&RoomId>::try_from(room_id)
            .map_err(|e| Error::Other(format!("invalid room ID: {e}")))?;
        let user_id = <&UserId>::try_from(user_id)
            .map_err(|e| Error::Other(format!("invalid user ID: {e}")))?;
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
            .map_err(|e| Error::Other(format!("invalid room ID: {e}")))?;
        let room = self
            .client
            .get_room(room_id)
            .ok_or_else(|| Error::Other(format!("room {} not found", room_id)))?;
        room.leave().await?;
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
        let resp = room.send(content).await?;
        Ok(resp.event_id.to_string())
    }

    /// Send a notice. Returns the event ID.
    pub async fn send_notice(&self, room_id: &str, body: &str) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::notice_plain(body);
        let resp = room.send(content).await?;
        Ok(resp.event_id.to_string())
    }

    /// Send an emote (/me). Returns the event ID.
    pub async fn send_emote(&self, room_id: &str, body: &str) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let content = RoomMessageEventContent::emote_plain(body);
        let resp = room.send(content).await?;
        Ok(resp.event_id.to_string())
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
        room.send(edit_content).await?;
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
        let resp = room.send(reply_content).await?;
        Ok(resp.event_id.to_string())
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
        let resp = room.send(content).await?;
        Ok(resp.event_id.to_string())
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
        body: &str,
    ) -> Result<String, Error> {
        let room = self.get_room_parsed(room_id)?;
        let event_id = <&EventId>::try_from(thread_root_event_id)
            .map_err(|e| Error::IdParse(format!("invalid event ID: {e}")))?;
        let original = self.fetch_original_message(&room, event_id).await?;
        let thread_content = RoomMessageEventContent::text_plain(body).make_for_thread(
            &original,
            ReplyWithinThread::Yes,
            AddMentions::Yes,
        );
        let resp = room.send(thread_content).await?;
        Ok(resp.event_id.to_string())
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
            .map_err(|e| Error::Other(format!("invalid user ID: {e}")))?;
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
            .map_err(|e| Error::Other(format!("invalid user ID: {e}")))?;
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

    /// Get the list of joined member user IDs for a room.
    pub async fn room_members(&self, room_id: &str) -> Result<Vec<String>, Error> {
        let room = self.get_room_parsed(room_id)?;
        let members = room.members(RoomMemberships::JOIN).await?;
        Ok(members.iter().map(|m| m.user_id().to_string()).collect())
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
            self.client.homeserver().to_string(),
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
        room.send_single_receipt(
            ReceiptType::Read,
            ReceiptThread::Unthreaded,
            event_id.to_owned(),
        )
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
        let resp = room
            .send_attachment(filename, &mime, data, AttachmentConfig::new())
            .await?;
        Ok(resp.event_id.to_string())
    }

    /// Download media content by mxc:// URI.
    pub async fn download_media(&self, mxc_uri: &str) -> Result<Vec<u8>, Error> {
        self.client
            .media()
            .get_media_content(
                &MediaRequestParameters {
                    source: plain_media_source_from_mxc(mxc_uri)?,
                    format: MediaFormat::File,
                },
                true,
            )
            .await
            .map_err(Error::from)
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
}

#[cfg(not(target_family = "wasm"))]
impl ManyMatrixClient {
    /// Build a new client pointing at `homeserver_url`, storing state under `store_path`.
    pub async fn new(homeserver_url: &str, store_path: impl AsRef<Path>) -> Result<Self, Error> {
        let store_path = store_path.as_ref();
        let client = Client::builder()
            .homeserver_url(homeserver_url)
            .sqlite_store(store_path, None)
            .handle_refresh_tokens()
            .build()
            .await?;
        Ok(Self {
            client,
            homeserver: homeserver_url.to_owned(),
            sync_token: Arc::new(Mutex::new(None)),
            store_path: store_path.to_owned(),
        })
    }

    /// Register a callback for incoming room messages.
    pub fn on_message<F>(&self, callback: F)
    where
        F: Fn(MessageEvent) + Send + Sync + 'static,
    {
        let callback = Arc::new(callback);
        self.client
            .add_event_handler(move |ev: SyncRoomMessageEvent, room: Room| {
                let callback = callback.clone();
                async move {
                    if let SyncRoomMessageEvent::Original(msg) = ev {
                        let msgtype = msg.content.msgtype().to_owned();
                        let body = msg.content.body().to_owned();
                        let formatted_body = match &msg.content.msgtype {
                            matrix_sdk::ruma::events::room::message::MessageType::Text(t) => {
                                t.formatted.as_ref().map(|f| f.body.clone())
                            }
                            matrix_sdk::ruma::events::room::message::MessageType::Notice(n) => {
                                n.formatted.as_ref().map(|f| f.body.clone())
                            }
                            matrix_sdk::ruma::events::room::message::MessageType::Emote(e) => {
                                e.formatted.as_ref().map(|f| f.body.clone())
                            }
                            _ => None,
                        };
                        let in_reply_to = msg.content.relates_to.as_ref().and_then(|rel| {
                            if let matrix_sdk::ruma::events::room::message::Relation::Reply {
                                in_reply_to,
                            } = rel
                            {
                                Some(in_reply_to.event_id.to_string())
                            } else {
                                None
                            }
                        });
                        let (mxc_uri, filename, file_size) = match &msg.content.msgtype {
                            matrix_sdk::ruma::events::room::message::MessageType::Image(img) => {
                                let uri = match &img.source {
                                    MediaSource::Plain(url) => Some(url.to_string()),
                                    MediaSource::Encrypted(_) => None,
                                };
                                let size = img.info.as_ref().and_then(|i| i.size).map(u64::from);
                                (uri, Some(img.body.clone()), size)
                            }
                            matrix_sdk::ruma::events::room::message::MessageType::File(f) => {
                                let uri = match &f.source {
                                    MediaSource::Plain(url) => Some(url.to_string()),
                                    MediaSource::Encrypted(_) => None,
                                };
                                let size = f.info.as_ref().and_then(|i| i.size).map(u64::from);
                                (
                                    uri,
                                    f.filename.clone().or_else(|| Some(f.body.clone())),
                                    size,
                                )
                            }
                            matrix_sdk::ruma::events::room::message::MessageType::Video(v) => {
                                let uri = match &v.source {
                                    MediaSource::Plain(url) => Some(url.to_string()),
                                    MediaSource::Encrypted(_) => None,
                                };
                                let size = v.info.as_ref().and_then(|i| i.size).map(u64::from);
                                (uri, Some(v.body.clone()), size)
                            }
                            matrix_sdk::ruma::events::room::message::MessageType::Audio(a) => {
                                let uri = match &a.source {
                                    MediaSource::Plain(url) => Some(url.to_string()),
                                    MediaSource::Encrypted(_) => None,
                                };
                                (uri, Some(a.body.clone()), None)
                            }
                            _ => (None, None, None),
                        };
                        let message = MessageEvent {
                            event_id: msg.event_id.to_string(),
                            room_id: room.room_id().to_string(),
                            sender: msg.sender.to_string(),
                            body,
                            formatted_body,
                            msgtype,
                            timestamp: msg.origin_server_ts.get().into(),
                            in_reply_to,
                            thread_root: None,
                            mxc_uri,
                            filename,
                            file_size,
                        };
                        callback(message);
                    }
                }
            });
    }

    /// Register a callback for incoming reactions.
    pub fn on_reaction<F>(&self, callback: F)
    where
        F: Fn(ReactionEvent) + Send + Sync + 'static,
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
        F: Fn(ReceiptEvent) + Send + Sync + 'static,
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
        let device_id = <&DeviceId>::try_from(device_id)
            .map_err(|e| Error::IdParse(format!("invalid device ID: {e}")))?;
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
        let verification = self
            .client
            .encryption()
            .get_verification(user_id, flow_id)
            .await
            .ok_or_else(|| Error::Other("verification not found".into()))?;
        let sas = verification
            .sas()
            .ok_or_else(|| Error::Other("not a SAS verification".into()))?;
        sas.cancel().await?;
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

    /// Returns the current user's Matrix ID (e.g. `@alice:example.com`), or `None` if not logged in.
    pub fn current_user_id(&self) -> Option<String> {
        self.client.user_id().map(|id| id.to_string())
    }

    /// Check whether a room has encryption enabled.
    pub async fn is_room_encrypted(&self, room_id: &str) -> Result<bool, Error> {
        let room = self.get_room_parsed(room_id)?;
        let encrypted = room.latest_encryption_state().await?.is_encrypted();
        Ok(encrypted)
    }
}

fn plain_media_source_from_mxc(mxc_uri: &str) -> Result<MediaSource, Error> {
    let uri = <&MxcUri>::try_from(mxc_uri)
        .map_err(|e| Error::IdParse(format!("invalid MXC URI: {e}")))?
        .to_owned();
    Ok(MediaSource::Plain(uri))
}

#[cfg(target_family = "wasm")]
impl ManyMatrixClient {
    /// Build a new client pointing at `homeserver_url`, storing state in the
    /// IndexedDB database named `store_name`.
    pub async fn new(homeserver_url: &str, store_name: &str) -> Result<Self, Error> {
        let client = Client::builder()
            .homeserver_url(homeserver_url)
            .indexeddb_store(store_name, None)
            .handle_refresh_tokens()
            .build()
            .await?;
        info!("WASM client built for {}", homeserver_url);
        Ok(Self {
            client,
            homeserver: homeserver_url.to_owned(),
            sync_token: Arc::new(Mutex::new(None)),
            store_path: PathBuf::from(store_name),
        })
    }
}
