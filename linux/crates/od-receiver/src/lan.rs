use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::Result;
use opendisplay_lan::{Authenticated, Endpoint, Intent, Peer, Prompt, Role, SENDER_SERVICE};
use tokio::{
    net::TcpStream,
    sync::{mpsc, watch},
    task::JoinSet,
    time::Instant,
};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub enum Command {
    Connect(Peer),
    Disconnect,
    Forget(Uuid),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub connected: bool,
    pub prompt: Option<(String, String)>,
    pub pairs: Vec<Uuid>,
}

#[derive(Clone)]
pub struct Control {
    pub peers: watch::Receiver<Vec<Peer>>,
    pub status: watch::Receiver<Status>,
    pub commands: mpsc::UnboundedSender<Command>,
}

pub struct LanReceiver {
    endpoint: Endpoint,
    pub commands: mpsc::UnboundedReceiver<Command>,
    pub status: watch::Sender<Status>,
    peers: watch::Receiver<Vec<Peer>>,
    prompt: Prompt,
    attempts: JoinSet<Result<(Authenticated, SocketAddr)>>,
    last_resume: Option<Instant>,
    outgoing: bool,
}

impl LanReceiver {
    pub fn start(id: Uuid, name: String, graphical: bool) -> Result<(Self, Control)> {
        let endpoint = Endpoint::open(Role::Receiver, Some(id), name)?;
        let (tx, peers) = watch::channel(Vec::new());
        tokio::spawn(async move {
            if let Err(error) = opendisplay_lan::browse(SENDER_SERVICE, tx).await {
                tracing::warn!("Wi-Fi discovery: {error}");
            }
        });
        let (status, status_rx) = watch::channel(Status {
            pairs: endpoint.store.pairs(),
            ..Status::default()
        });
        let (command_tx, commands) = mpsc::unbounded_channel();
        let show = status.clone();
        let prompt: Prompt = Arc::new(move |name, code| {
            if !graphical {
                return opendisplay_lan::terminal_code(name, code);
            }
            let code = code?;
            show.send_modify(|state| state.prompt = Some((name.to_string(), code.to_string())));
            Some(code.to_string())
        });
        let control = Control {
            peers: peers.clone(),
            status: status_rx,
            commands: command_tx,
        };
        Ok((
            Self {
                endpoint,
                commands,
                status,
                peers,
                prompt,
                attempts: JoinSet::new(),
                last_resume: None,
                outgoing: false,
            },
            control,
        ))
    }

    pub fn accept(&mut self, tcp: TcpStream, addr: SocketAddr) {
        if !self.attempts.is_empty() {
            if !self.outgoing {
                return;
            }
            // Sender-opened sockets have priority during simultaneous clicks.
            self.attempts.abort_all();
        }
        self.outgoing = false;
        let endpoint = self.endpoint.clone();
        let store = endpoint.store.clone();
        let inspect = Arc::new(move |id, intent| {
            intent == Intent::Connect || store.resume_peer() == Some(id)
        });
        let prompt = self.prompt.clone();
        self.attempts.spawn(async move {
            endpoint
                .accept(tcp, inspect, prompt)
                .await
                .map(|link| (link, addr))
        });
    }

    pub fn connect(&mut self, peer: Peer, intent: Intent) {
        if !self.attempts.is_empty() {
            return;
        }
        self.outgoing = true;
        let endpoint = self.endpoint.clone();
        let prompt = self.prompt.clone();
        self.attempts.spawn(async move {
            endpoint
                .connect(
                    peer.address,
                    Some(peer.id),
                    intent,
                    Arc::new(|_, _| true),
                    prompt,
                )
                .await
                .map(|link| (link, peer.address))
        });
    }

    pub fn resume(&mut self) {
        if !self.attempts.is_empty()
            || self
                .last_resume
                .is_some_and(|time| time.elapsed() < Duration::from_secs(5))
        {
            return;
        }
        let Some(id) = self.endpoint.store.resume_peer() else {
            return;
        };
        let peer = self
            .peers
            .borrow()
            .iter()
            .find(|peer| peer.id == id)
            .cloned();
        if let Some(peer) = peer {
            self.last_resume = Some(Instant::now());
            self.connect(peer, Intent::Resume);
        }
    }

    pub fn remember(&self, id: Uuid) {
        self.endpoint.store.remember(id);
        self.refresh_pairs();
    }
    pub fn pause(&self) {
        self.endpoint.store.pause();
    }
    pub fn forget(&self, id: Uuid) {
        self.endpoint.store.forget(id);
        self.refresh_pairs();
    }

    fn refresh_pairs(&self) {
        let mut pairs = self.endpoint.store.pairs();
        pairs.sort_unstable();
        self.status.send_modify(|state| state.pairs = pairs);
    }

    pub async fn event(&mut self) -> Event {
        tokio::select! {
            result = self.attempts.join_next(), if !self.attempts.is_empty() => {
                if self.attempts.is_empty() {
                    self.status.send_modify(|state| state.prompt = None);
                    self.outgoing = false;
                }
                match result {
                    Some(Ok(Ok((link, addr)))) => Event::Connected(link, addr),
                    Some(Ok(Err(error))) => { tracing::warn!("Wi-Fi connection: {error}"); Event::None }
                    _ => Event::None,
                }
            }
            Some(command) = self.commands.recv() => Event::Command(command),
            else => std::future::pending().await,
        }
    }
}

pub enum Event {
    None,
    Connected(Authenticated, SocketAddr),
    Command(Command),
}
