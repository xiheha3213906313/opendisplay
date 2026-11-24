use anyhow::{Context, Result, bail};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::{
    collections::{HashMap, HashSet},
    ffi::{CStr, CString, c_char, c_int, c_void},
    fs::{self, OpenOptions},
    io::Write,
    net::SocketAddr,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    runtime::Handle,
    time::{Instant, timeout, timeout_at},
};
use tokio_rustls::{
    TlsAcceptor, TlsConnector, TlsStream,
    rustls::{
        self, ClientConfig, ClientConnection, DigitallySignedStruct, ServerConfig, SignatureScheme,
        client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        crypto::{CryptoProvider, verify_tls13_signature},
        pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    },
};
use uuid::Uuid;

pub const SENDER_SERVICE: &str = "_od-sender._tcp.local.";
pub const RECEIVER_SERVICE: &str = "_od-receiver._tcp.local.";
const ALPN: &[u8] = b"opendisplay/1";
const EXPORTER: &[u8] = b"EXPORTER-OpenDisplay-LAN-v1";

pub trait MediaIo: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> MediaIo for T {}
pub type MediaStream = Box<dyn MediaIo>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub id: Uuid,
    pub name: String,
    pub address: SocketAddr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Intent {
    Incoming = 0,
    Connect = 1,
    Resume = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Sender,
    Receiver,
}

pub type Inspect = Arc<dyn Fn(Uuid, Intent) -> bool + Send + Sync>;
pub type Prompt = Arc<dyn Fn(&str, Option<&str>) -> Option<String> + Send + Sync>;

#[derive(Clone)]
pub struct Store(PathBuf);

impl Store {
    pub fn open(role: Role) -> Result<Self> {
        let state = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
            })
            .context("no home directory for OpenDisplay pairing keys")?;
        let directory = state.join("opendisplay").join(match role {
            Role::Sender => "sender-pairing",
            Role::Receiver => "receiver-pairing",
        });
        fs::create_dir_all(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        Ok(Self(directory))
    }

    pub fn installation_id(&self) -> Result<Uuid> {
        let path = self.0.join("id");
        if let Ok(saved) = fs::read_to_string(&path) {
            return Ok(Uuid::parse_str(saved.trim())?);
        }
        let id = Uuid::new_v4();
        match secure_write(&path, id.to_string().as_bytes(), false) {
            Ok(()) => Ok(id),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                Ok(Uuid::parse_str(fs::read_to_string(path)?.trim())?)
            }
            Err(e) => Err(e.into()),
        }
    }

    fn key_path(&self, peer: Uuid) -> PathBuf {
        self.0.join(format!("{peer}.key"))
    }

    fn key(&self, peer: Uuid) -> Option<[u8; 32]> {
        fs::read(self.key_path(peer)).ok()?.try_into().ok()
    }

    fn save_key(&self, peer: Uuid, secret: &[u8; 32]) -> Result<()> {
        let tmp = self.0.join(format!("{}.tmp", Uuid::new_v4()));
        secure_write(&tmp, secret, false)?;
        let renamed = fs::rename(&tmp, self.key_path(peer));
        if renamed.is_err() {
            let _ = fs::remove_file(tmp);
        }
        Ok(renamed?)
    }

    pub fn forget(&self, peer: Uuid) {
        let _ = fs::remove_file(self.key_path(peer));
        if self.resume_peer() == Some(peer) {
            self.pause();
        }
    }

    pub fn pairs(&self) -> Vec<Uuid> {
        fs::read_dir(&self.0)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name();
                let id = name.to_str()?.strip_suffix(".key")?;
                Uuid::parse_str(id).ok()
            })
            .collect()
    }

    pub fn remember(&self, peer: Uuid) {
        let _ = secure_write(&self.0.join("resume"), peer.to_string().as_bytes(), true);
    }

    pub fn resume_peer(&self) -> Option<Uuid> {
        Uuid::parse_str(fs::read_to_string(self.0.join("resume")).ok()?.trim()).ok()
    }

    pub fn pause(&self) {
        let _ = fs::remove_file(self.0.join("resume"));
    }
}

fn secure_write(path: &Path, bytes: &[u8], replace: bool) -> std::io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).mode(0o600);
    if replace {
        options.create(true).truncate(true);
    } else {
        options.create_new(true);
    }
    options.open(path)?.write_all(bytes)
}

#[derive(Debug)]
struct PAKEVerifier(Arc<CryptoProvider>);

impl ServerCertVerifier for PAKEVerifier {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        // A successful TLS handshake alone never opens a media session.
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General(
            "OpenDisplay LAN requires TLS 1.3".into(),
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            signature,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[derive(Clone)]
pub struct Endpoint {
    id: Uuid,
    name: String,
    role: Role,
    pub store: Store,
    server: TlsAcceptor,
    client: TlsConnector,
}

pub struct Authenticated {
    pub stream: MediaStream,
    pub id: Uuid,
    pub name: String,
    pub intent: Intent,
}

impl Endpoint {
    pub fn open(role: Role, id: Option<Uuid>, name: String) -> Result<Self> {
        Self::with_store(role, id, name, Store::open(role)?)
    }

    fn with_store(role: Role, id: Option<Uuid>, name: String, store: Store) -> Result<Self> {
        let id = match id {
            Some(id) => id,
            None => store.installation_id()?,
        };
        let mut cert = vec![0; 1024];
        let mut key = vec![0; 256];
        let mut raw = [0; 97];
        let (mut cert_size, mut key_size) = (cert.len(), key.len());
        // SAFETY: the buffers hold exactly the sizes declared to C.
        if unsafe {
            od_pair_identity(
                cert.as_mut_ptr(),
                &mut cert_size,
                key.as_mut_ptr(),
                &mut key_size,
                raw.as_mut_ptr(),
            )
        } != 1
        {
            bail!("could not create TLS identity")
        }
        cert.truncate(cert_size);
        key.truncate(key_size);
        raw.fill(0);
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut server = ServerConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert)],
                PrivateKeyDer::from(PrivatePkcs8KeyDer::from(key)),
            )?;
        server.alpn_protocols = vec![ALPN.to_vec()];
        server.send_tls13_tickets = 0;
        let mut client = ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PAKEVerifier(provider)))
            .with_no_client_auth();
        client.alpn_protocols = vec![ALPN.to_vec()];
        client.enable_early_data = false;
        Ok(Self {
            id,
            name,
            role,
            store,
            server: TlsAcceptor::from(Arc::new(server)),
            client: TlsConnector::from(Arc::new(client)),
        })
    }

    pub fn id(&self) -> Uuid {
        self.id
    }

    pub async fn accept(
        &self,
        tcp: TcpStream,
        inspect: Inspect,
        prompt: Prompt,
    ) -> Result<Authenticated> {
        tcp.set_nodelay(true)?;
        let tls = timeout(Duration::from_secs(5), self.server.accept(tcp)).await??;
        self.authenticate(tls.into(), Intent::Incoming, None, inspect, prompt)
            .await
    }

    pub async fn connect(
        &self,
        addr: SocketAddr,
        expected: Option<Uuid>,
        intent: Intent,
        inspect: Inspect,
        prompt: Prompt,
    ) -> Result<Authenticated> {
        let tcp = timeout(Duration::from_secs(5), TcpStream::connect(addr)).await??;
        tcp.set_nodelay(true)?;
        let tls = timeout(
            Duration::from_secs(5),
            self.client
                .connect(ServerName::try_from("opendisplay.local")?, tcp),
        )
        .await??;
        self.authenticate(tls.into(), intent, expected, inspect, prompt)
            .await
    }

    async fn authenticate(
        &self,
        tls: TlsStream<TcpStream>,
        intent: Intent,
        expected: Option<Uuid>,
        inspect: Inspect,
        prompt: Prompt,
    ) -> Result<Authenticated> {
        let connection = tls.get_ref().1;
        if connection.alpn_protocol() != Some(ALPN) {
            bail!("incompatible LAN protocol");
        }
        let exporter = match &tls {
            TlsStream::Client(stream) => export_client(stream.get_ref().1)?,
            TlsStream::Server(stream) => stream
                .get_ref()
                .1
                .export_keying_material([0; 32], EXPORTER, None)?,
        };
        let state = Channel {
            rt: Handle::current(),
            stream: tls,
            deadline: Instant::now() + Duration::from_secs(120),
            store: self.store.clone(),
            inspect,
            prompt,
            expected,
        };
        let id = CString::new(self.id.to_string())?;
        let name = CString::new(if self.name.len() <= 120 {
            self.name.as_str()
        } else {
            "OpenDisplay"
        })?;
        let sender = self.role == Role::Sender;
        tokio::task::spawn_blocking(move || state.run(sender, intent, id, name, exporter)).await?
    }
}

fn export_client(connection: &ClientConnection) -> Result<[u8; 32], rustls::Error> {
    connection.export_keying_material([0; 32], EXPORTER, None)
}

struct Channel {
    rt: Handle,
    stream: TlsStream<TcpStream>,
    deadline: Instant,
    store: Store,
    inspect: Inspect,
    prompt: Prompt,
    expected: Option<Uuid>,
}

#[repr(C)]
struct Io {
    read: unsafe extern "C" fn(*mut c_void, *mut u8, usize) -> c_int,
    write: unsafe extern "C" fn(*mut c_void, *const u8, usize) -> c_int,
    inspect: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, c_int) -> c_int,
    load: unsafe extern "C" fn(*mut c_void, *const c_char, *mut u8) -> c_int,
    code: unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, c_int) -> c_int,
}

#[repr(C)]
struct PairResult {
    id: [c_char; 37],
    name: [c_char; 121],
    secret: [u8; 32],
    fresh: c_int,
    request: c_int,
}

unsafe extern "C" {
    fn od_pair_identity(
        cert: *mut u8,
        cert_size: *mut usize,
        key: *mut u8,
        key_size: *mut usize,
        raw: *mut u8,
    ) -> c_int;
    fn od_lan_handshake(
        io: *const Io,
        context: *mut c_void,
        sender: c_int,
        request: c_int,
        id: *const c_char,
        name: *const c_char,
        exporter: *const u8,
        result: *mut PairResult,
    ) -> c_int;
}

impl Channel {
    fn run(
        mut self,
        sender: bool,
        intent: Intent,
        id: CString,
        name: CString,
        exporter: [u8; 32],
    ) -> Result<Authenticated> {
        let io = Io {
            read: read_io,
            write: write_io,
            inspect: inspect_io,
            load: load_io,
            code: code_io,
        };
        let mut result = PairResult {
            id: [0; 37],
            name: [0; 121],
            secret: [0; 32],
            fresh: 0,
            request: 0,
        };
        // SAFETY: od_lan_handshake is synchronous; the buffers and Channel
        // stay alive and the callbacks use the same exclusive context.
        let status = unsafe {
            od_lan_handshake(
                &io,
                (&mut self as *mut Self).cast(),
                sender.into(),
                intent as i32,
                id.as_ptr(),
                name.as_ptr(),
                exporter.as_ptr(),
                &mut result,
            )
        };
        match status {
            1 => (),
            -2 => bail!("pair again before resuming"),
            -3 => bail!("verification failed; forget the pairing to pair again"),
            _ => bail!("pairing cancelled, expired or incompatible"),
        }
        // SAFETY: the C introduction decoder leaves both fields terminated.
        let id = Uuid::parse_str(unsafe { CStr::from_ptr(result.id.as_ptr()) }.to_str()?)?;
        let name = unsafe { CStr::from_ptr(result.name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if result.fresh != 0 {
            self.store.save_key(id, &result.secret)?;
        }
        result.secret.fill(0);
        Ok(Authenticated {
            stream: Box::new(self.stream),
            id,
            name,
            intent: if result.request == 1 {
                Intent::Connect
            } else {
                Intent::Resume
            },
        })
    }
}

unsafe extern "C" fn read_io(context: *mut c_void, bytes: *mut u8, size: usize) -> c_int {
    // SAFETY: C supplies a live Channel and output buffer for this call.
    let channel = unsafe { &mut *context.cast::<Channel>() };
    let output = unsafe { std::slice::from_raw_parts_mut(bytes, size) };
    channel.rt.block_on(async {
        matches!(
            timeout_at(channel.deadline, channel.stream.read_exact(output)).await,
            Ok(Ok(_))
        )
        .into()
    })
}

unsafe extern "C" fn write_io(context: *mut c_void, bytes: *const u8, size: usize) -> c_int {
    let channel = unsafe { &mut *context.cast::<Channel>() };
    let input = unsafe { std::slice::from_raw_parts(bytes, size) };
    channel.rt.block_on(async {
        matches!(
            timeout_at(channel.deadline, async {
                channel.stream.write_all(input).await?;
                channel.stream.flush().await
            })
            .await,
            Ok(Ok(()))
        )
        .into()
    })
}

unsafe extern "C" fn inspect_io(
    context: *mut c_void,
    id: *const c_char,
    _: *const c_char,
    request: c_int,
) -> c_int {
    let channel = unsafe { &mut *context.cast::<Channel>() };
    let Ok(id) = Uuid::parse_str(&unsafe { CStr::from_ptr(id) }.to_string_lossy()) else {
        return 0;
    };
    if channel.expected.is_some_and(|expected| expected != id) {
        return 0;
    }
    (channel.inspect)(
        id,
        if request == 1 {
            Intent::Connect
        } else {
            Intent::Resume
        },
    )
    .into()
}

unsafe extern "C" fn load_io(context: *mut c_void, id: *const c_char, key: *mut u8) -> c_int {
    let channel = unsafe { &mut *context.cast::<Channel>() };
    let Ok(id) = Uuid::parse_str(&unsafe { CStr::from_ptr(id) }.to_string_lossy()) else {
        return 0;
    };
    let Some(secret) = channel.store.key(id) else {
        return 0;
    };
    unsafe {
        std::ptr::copy_nonoverlapping(secret.as_ptr(), key, 32);
    }
    1
}

unsafe extern "C" fn code_io(
    context: *mut c_void,
    name: *const c_char,
    code: *mut c_char,
    display: c_int,
) -> c_int {
    let channel = unsafe { &mut *context.cast::<Channel>() };
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy();
    let shown =
        (display != 0).then(|| unsafe { CStr::from_ptr(code) }.to_str().unwrap_or_default());
    let Some(value) = (channel.prompt)(&name, shown) else {
        return 0;
    };
    if value.len() != 6 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), code.cast(), 6);
    }
    1
}

pub struct Advertisement(ServiceDaemon, String);

impl Drop for Advertisement {
    fn drop(&mut self) {
        let _ = self.0.unregister(&self.1);
        let _ = self.0.shutdown();
    }
}

pub fn advertise(role: Role, name: &str, port: u16, id: Uuid) -> Result<Advertisement> {
    let service = if role == Role::Sender {
        SENDER_SERVICE
    } else {
        RECEIVER_SERVICE
    };
    let daemon = ServiceDaemon::new()?;
    let record = HashMap::from([
        ("id".to_string(), id.to_string()),
        ("auth".to_string(), "1".to_string()),
    ]);
    let host = format!("opendisplay-{}.local.", id.simple());
    let info = ServiceInfo::new(service, name, &host, "", port, record)?.enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon.register(info)?;
    Ok(Advertisement(daemon, fullname))
}

pub async fn browse(
    service: &'static str,
    peers: tokio::sync::watch::Sender<Vec<Peer>>,
) -> Result<()> {
    let daemon = ServiceDaemon::new()?;
    let changes = daemon.browse(service)?;
    let mut records = HashMap::new();
    loop {
        tokio::select! {
            _ = peers.closed() => break,
            change = changes.recv_async() => match change? {
                ServiceEvent::ServiceResolved(info) => {
                    let Some(id) = info.get_property_val_str("id").and_then(|value| Uuid::parse_str(value).ok()) else { continue };
                    if info.get_property_val_str("auth") != Some("1") { continue; }
                    let port = info.get_port();
                    let Some(address) = info.get_addresses().iter().filter_map(|address|
                        address.to_string().parse::<std::net::IpAddr>().ok())
                        .filter(|address| !matches!(address, std::net::IpAddr::V6(v6) if v6.is_unicast_link_local()))
                        .min_by_key(|address| address.is_ipv6()) else { continue; };
                    let fullname = info.get_fullname();
                    let name = fullname.strip_suffix(service).unwrap_or(fullname).trim_end_matches('.');
                    records.insert(fullname.to_string(), Peer { id, name: name.to_string(),
                        address: SocketAddr::new(address, port) });
                }
                ServiceEvent::ServiceRemoved(_, name) => { records.remove(&name); }
                _ => continue,
            }
        }
        let mut seen = HashSet::new();
        let mut list: Vec<_> = records.values().cloned().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
        list.retain(|peer| seen.insert(peer.id));
        peers.send_replace(list);
    }
    let _ = daemon.stop_browse(service);
    let _ = daemon.shutdown();
    Ok(())
}

pub fn local_name() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Linux".into())
}

pub fn terminal_code(name: &str, displayed: Option<&str>) -> Option<String> {
    use std::io::IsTerminal;
    if let Some(code) = displayed {
        if !std::io::stderr().is_terminal() {
            return None;
        }
        eprintln!("Enter this code on {name}: {code}");
        return Some(code.to_string());
    }
    if !std::io::stdin().is_terminal() {
        return None;
    }
    eprint!("Enter the six-digit code shown on {name}: ");
    let _ = std::io::stderr().flush();
    let mut input = String::new();
    let mut fd = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN,
        revents: 0,
    };
    if unsafe { libc::poll(&mut fd, 1, 120_000) } <= 0 {
        return None;
    }
    std::io::stdin().read_line(&mut input).ok()?;
    Some(input.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test(flavor = "multi_thread")]
    async fn receiver_initiates_and_resumes_with_tls() -> Result<()> {
        let sender_dir = tempfile::tempdir()?;
        let receiver_dir = tempfile::tempdir()?;
        let sender = Endpoint::with_store(
            Role::Sender,
            None,
            "Computer".into(),
            Store(sender_dir.path().to_path_buf()),
        )?;
        let receiver = Endpoint::with_store(
            Role::Receiver,
            None,
            "Tablet".into(),
            Store(receiver_dir.path().to_path_buf()),
        )?;

        for intent in [Intent::Connect, Intent::Resume] {
            let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
            let addr = listener.local_addr()?;
            let (code_tx, code_rx) = std::sync::mpsc::sync_channel(1);
            let code_rx = std::sync::Mutex::new(code_rx);
            let read_code: Prompt = Arc::new(move |_, displayed| {
                if displayed.is_some() || intent == Intent::Resume {
                    return None;
                }
                code_rx
                    .lock()
                    .ok()?
                    .recv_timeout(Duration::from_secs(5))
                    .ok()
            });
            let show_code: Prompt = Arc::new(move |_, code| {
                if intent == Intent::Resume {
                    return None;
                }
                let digits = code?.to_string();
                code_tx.send(digits.clone()).ok()?;
                Some(digits)
            });
            let sender_id = sender.id();
            let receiver_id = receiver.id();
            let allowed = Arc::new(move |id, request| id == receiver_id && request == intent);
            let (outbound, inbound) = tokio::try_join!(
                receiver.connect(
                    addr,
                    Some(sender_id),
                    intent,
                    Arc::new(|_, _| true),
                    show_code
                ),
                async {
                    let (socket, _) = listener.accept().await?;
                    sender.accept(socket, allowed, read_code).await
                },
            )?;
            assert_eq!(outbound.id, sender_id);
            assert_eq!(inbound.id, receiver_id);
            let mut outgoing = outbound.stream;
            let mut incoming = inbound.stream;
            outgoing.write_all(b"hello").await?;
            let mut received = [0; 5];
            incoming.read_exact(&mut received).await?;
            assert_eq!(&received, b"hello");
        }
        Ok(())
    }
}
