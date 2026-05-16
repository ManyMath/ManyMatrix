use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use manymatrix_core::{CreateRoomOptions, ManyMatrixClient, StoredSession};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "manymatrix-cli", about = "Minimal ManyMatrix CLI client")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Login to a homeserver
    Login {
        /// Homeserver URL or server name (e.g. matrix.org)
        #[arg(short = 's', long)]
        server: String,
        /// Username (local part or full @user:server)
        #[arg(short, long)]
        user: String,
    },
    /// Start syncing and print incoming messages
    Sync,
    /// List joined rooms
    Rooms,
    /// Send a message to a room
    Send {
        /// Room ID (e.g. !abc:matrix.org)
        #[arg(short, long)]
        room: String,
        /// Message text
        message: String,
    },
    /// Create a new room
    CreateRoom {
        /// Room name
        #[arg(short, long)]
        name: Option<String>,
        /// Room topic
        #[arg(short, long)]
        topic: Option<String>,
    },
    /// Join a room by ID or alias
    Join {
        /// Room ID (!abc:server) or alias (#name:server)
        room: String,
    },
    /// Invite a user to a room
    Invite {
        /// Room ID
        #[arg(short, long)]
        room: String,
        /// User ID to invite (@user:server)
        user: String,
    },
    /// Leave a room
    Leave {
        /// Room ID
        room: String,
    },
    /// Kick a user from a room
    Kick {
        /// Room ID
        #[arg(short, long)]
        room: String,
        /// User ID to kick
        user: String,
        /// Reason for kick
        #[arg(long)]
        reason: Option<String>,
    },
    /// Ban a user from a room
    Ban {
        /// Room ID
        #[arg(short, long)]
        room: String,
        /// User ID to ban
        user: String,
        /// Reason for ban
        #[arg(long)]
        reason: Option<String>,
    },
    /// Logout and remove session
    Logout,
}

fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("manymatrix-cli")
}

fn session_path() -> PathBuf {
    data_dir().join("session.json")
}

fn store_path() -> PathBuf {
    data_dir().join("store")
}

async fn load_client() -> Result<ManyMatrixClient> {
    let stored = StoredSession::load(&session_path())
        .context("no saved session, run `manymatrix-cli login` first")?;
    let client = ManyMatrixClient::new(&stored.homeserver, &store_path()).await?;
    client.restore(&stored).await?;
    Ok(client)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Command::Login { server, user } => {
            let password = rpassword::prompt_password("Password: ")?;
            let client = ManyMatrixClient::new(&server, &store_path()).await?;
            let session = client.login(&user, &password).await?;
            session.save(&session_path())?;
            println!(
                "Logged in as {} (device {})",
                session.session.meta.user_id, session.session.meta.device_id
            );
        }
        Command::Sync => {
            let client = load_client().await?;
            println!("Syncing... (Ctrl+C to stop)");
            client.sync_forever().await?;
        }
        Command::Rooms => {
            let client = load_client().await?;
            client.sync_once().await?;
            let rooms = client.joined_rooms().await;
            if rooms.is_empty() {
                println!("No joined rooms.");
            } else {
                for room in &rooms {
                    let preview = room
                        .last_message
                        .as_ref()
                        .map(|m| format!("{}: {}", m.sender, m.body))
                        .unwrap_or_default();
                    println!(
                        "  {} - {} [{}] {}",
                        room.room_id, room.display_name, room.unread_count, preview
                    );
                }
            }
        }
        Command::Send { room, message } => {
            let client = load_client().await?;
            client.sync_once().await?;
            client.send_text(&room, &message).await?;
            println!("Sent.");
        }
        Command::CreateRoom { name, topic } => {
            let client = load_client().await?;
            client.sync_once().await?;
            let room_id = client
                .create_room(CreateRoomOptions {
                    name,
                    topic,
                    ..Default::default()
                })
                .await?;
            println!("Created room: {}", room_id);
        }
        Command::Join { room } => {
            let client = load_client().await?;
            client.sync_once().await?;
            let room_id = client.join_room(&room).await?;
            println!("Joined room: {}", room_id);
        }
        Command::Invite { room, user } => {
            let client = load_client().await?;
            client.sync_once().await?;
            client.invite(&room, &user).await?;
            println!("Invited {} to {}", user, room);
        }
        Command::Leave { room } => {
            let client = load_client().await?;
            client.sync_once().await?;
            client.leave_room(&room).await?;
            println!("Left room {}", room);
        }
        Command::Kick { room, user, reason } => {
            let client = load_client().await?;
            client.sync_once().await?;
            client.kick(&room, &user, reason.as_deref()).await?;
            println!("Kicked {} from {}", user, room);
        }
        Command::Ban { room, user, reason } => {
            let client = load_client().await?;
            client.sync_once().await?;
            client.ban(&room, &user, reason.as_deref()).await?;
            println!("Banned {} from {}", user, room);
        }
        Command::Logout => {
            let client = load_client().await?;
            client.logout().await?;
            let _ = std::fs::remove_file(session_path());
            println!("Logged out and session removed.");
        }
    }

    Ok(())
}
