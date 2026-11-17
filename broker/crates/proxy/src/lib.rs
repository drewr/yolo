//! The sandbox side: a local HTTP CONNECT proxy. Hosts the broker lists for
//! this sandbox's endpoint id go over iroh to the broker; every other CONNECT
//! is spliced straight to its destination, so ordinary traffic never touches
//! the jump box.
//!
//! The patterns are fetched from the broker at startup and refreshed
//! periodically. If the broker cannot be reached the last known patterns stay
//! in force (none at startup), so unlisted traffic is never held up. Traffic
//! to a listed host is never sent direct while the broker is unreachable once
//! its pattern is known.

pub mod dial;

use std::net::SocketAddr;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use iroh::endpoint::{Connection, RecvStream, SendStream, VarInt};
use iroh::{Endpoint, EndpointAddr, EndpointId};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, info, warn};
use yolo_broker_wire::{
    bind_endpoint, read_frame, split_authority, write_frame, EndpointOpts, HostPattern, Network,
    Request, Response, ALPN,
};

pub struct Config {
    pub secret: iroh::SecretKey,
    /// Where the broker is: its id, plus direct addresses when not using the
    /// default network.
    pub broker: EndpointAddr,
    pub network: Network,
    /// Where the CONNECT proxy listens: typically `127.0.0.1:3128` and
    /// `[::1]:3128`, so a client that resolves `localhost` to either works.
    pub listen: Vec<SocketAddr>,
    /// `listen` is the default pair rather than the user's choice, so an
    /// address the host cannot bind (no IPv6) is skipped with a warning
    /// instead of failing. At least one must bind.
    pub listen_is_default: bool,
    /// Local addresses for the iroh endpoint, at most one per IP family
    /// (empty: iroh's wildcards for both).
    pub bind: Vec<SocketAddr>,
    pub refresh: Duration,
    /// How long one exchange with the broker (open a stream, send a request,
    /// read the reply) may take before the connection is judged dead and
    /// replaced. Default for the binary: 10 seconds.
    pub rpc_timeout: Duration,
}

pub struct Proxy {
    /// Where the CONNECT proxy listens, the first of `local_addrs` (resolves a
    /// port-0 `listen`).
    pub local_addr: SocketAddr,
    /// Every address it listens on, in `listen` order.
    pub local_addrs: Vec<SocketAddr>,
    /// This sandbox's endpoint id, the one to put in the broker's policy.
    pub id: EndpointId,
    inner: Arc<Inner>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Proxy {
    /// Patterns currently routed through the broker, canonical form.
    pub fn patterns(&self) -> Vec<String> {
        self.inner
            .patterns
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|p| p.to_string())
            .collect()
    }

    pub async fn shutdown(self) {
        for t in &self.tasks {
            t.abort();
        }
        self.inner.endpoint.close().await;
    }
}

struct Inner {
    endpoint: Endpoint,
    broker: EndpointAddr,
    conn: tokio::sync::Mutex<Option<Connection>>,
    rpc_timeout: Duration,
    patterns: RwLock<Vec<HostPattern>>,
}

pub async fn start(cfg: Config) -> Result<Proxy> {
    let endpoint = bind_endpoint(
        cfg.secret,
        cfg.network,
        vec![],
        EndpointOpts::bind(cfg.bind),
    )
    .await?;
    let inner = Arc::new(Inner {
        endpoint,
        broker: cfg.broker,
        conn: tokio::sync::Mutex::new(None),
        rpc_timeout: cfg.rpc_timeout,
        patterns: RwLock::new(Vec::new()),
    });
    let id = inner.endpoint.id();

    match tokio::time::timeout(Duration::from_secs(15), inner.refresh()).await {
        Ok(Ok(n)) => info!(id = %id, patterns = n, "policy loaded from broker"),
        Ok(Err(e)) => warn!(id = %id, "could not load policy from broker yet: {e:#}"),
        Err(_) => warn!(id = %id, "timed out loading policy from broker"),
    }

    let mut listeners = Vec::new();
    for addr in &cfg.listen {
        match TcpListener::bind(addr).await {
            Ok(l) => listeners.push(l),
            Err(e) if cfg.listen_is_default => warn!("not listening on {addr}: {e}"),
            Err(e) => return Err(e).with_context(|| format!("listen {addr}")),
        }
    }
    if listeners.is_empty() {
        bail!("could not listen on any of {:?}", cfg.listen);
    }
    let local_addrs = listeners
        .iter()
        .map(|l| l.local_addr())
        .collect::<std::io::Result<Vec<_>>>()?;
    info!(addrs = ?local_addrs, id = %id, "CONNECT proxy listening");

    let refresher = {
        let inner = inner.clone();
        let every = cfg.refresh;
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                match tokio::time::timeout(Duration::from_secs(15), inner.refresh()).await {
                    Ok(Ok(_)) => {}
                    Ok(Err(e)) => {
                        warn!("policy refresh failed, keeping the previous patterns: {e:#}")
                    }
                    Err(_) => warn!("policy refresh timed out, keeping the previous patterns"),
                }
            }
        })
    };
    let mut tasks = vec![refresher];
    for listener in listeners {
        let inner = inner.clone();
        tasks.push(tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((sock, _)) => {
                        let inner = inner.clone();
                        tokio::spawn(async move {
                            if let Err(e) = inner.client(sock).await {
                                debug!("client: {e:#}");
                            }
                        });
                    }
                    Err(e) => {
                        warn!("accept: {e}");
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            }
        }));
    }
    Ok(Proxy {
        local_addr: local_addrs[0],
        local_addrs,
        id,
        inner,
        tasks,
    })
}

impl Inner {
    /// The cached connection to the broker, or a new one. One dial at a time:
    /// callers that arrive meanwhile wait and share its result.
    async fn connection(&self) -> Result<Connection> {
        let mut cached = self.conn.lock().await;
        if let Some(c) = cached.as_ref() {
            if c.close_reason().is_none() {
                return Ok(c.clone());
            }
        }
        let conn = tokio::time::timeout(
            self.rpc_timeout,
            self.endpoint.connect(self.broker.clone(), ALPN),
        )
        .await
        .map_err(|_| anyhow!("timed out connecting to the broker"))?
        .context("connecting to the broker")?;
        *cached = Some(conn.clone());
        Ok(conn)
    }

    /// Drop `conn` from the cache, unless someone already replaced it.
    async fn discard(&self, conn: &Connection) {
        let mut cached = self.conn.lock().await;
        if cached
            .as_ref()
            .is_some_and(|c| c.stable_id() == conn.stable_id())
        {
            *cached = None;
        }
        conn.close(VarInt::from_u32(0), b"stale");
    }

    /// Send one control request and read its reply. A stale or dead cached
    /// connection (the broker restarted, the network moved) is replaced and
    /// the exchange retried once. A reply, even a refusal, is never retried.
    async fn exchange(&self, req: &Request) -> Result<(SendStream, RecvStream, Response)> {
        let mut last = anyhow!("no attempt made");
        for _ in 0..2 {
            let conn = match self.connection().await {
                Ok(c) => c,
                Err(e) => {
                    last = e;
                    continue;
                }
            };
            let attempt = async {
                let (mut send, mut recv) = conn
                    .open_bi()
                    .await
                    .context("opening a stream to the broker")?;
                write_frame(&mut send, req).await?;
                let reply: Response = read_frame(&mut recv)
                    .await
                    .context("the broker closed the stream (is this endpoint id in its policy?)")?;
                Ok::<_, anyhow::Error>((send, recv, reply))
            };
            match tokio::time::timeout(self.rpc_timeout, attempt).await {
                Ok(Ok(r)) => return Ok(r),
                Ok(Err(e)) => last = e,
                Err(_) => last = anyhow!("timed out talking to the broker"),
            }
            self.discard(&conn).await;
        }
        Err(last)
    }

    async fn refresh(&self) -> Result<usize> {
        let (mut send, _recv, reply) = self.exchange(&Request::Policy).await?;
        let _ = send.finish();
        match reply {
            Response::Policy { hosts } => {
                let parsed = hosts
                    .iter()
                    .map(|h| HostPattern::parse(h))
                    .collect::<Result<Vec<_>>>()?;
                let n = parsed.len();
                *self
                    .patterns
                    .write()
                    .unwrap_or_else(PoisonError::into_inner) = parsed;
                Ok(n)
            }
            Response::Refused { reason } => bail!("broker refused: {reason}"),
            Response::Connected => bail!("unexpected reply from the broker"),
        }
    }

    fn brokered(&self, host: &str, port: u16) -> bool {
        self.patterns
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|p| p.matches(host, port))
    }

    async fn client(&self, mut sock: TcpStream) -> Result<()> {
        let (head, leftover) = read_head(&mut sock).await?;
        let line = head.lines().next().unwrap_or("");
        let mut parts = line.split_whitespace();
        let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        if !method.eq_ignore_ascii_case("CONNECT") {
            sock.write_all(b"HTTP/1.1 405 Method Not Allowed\r\nAllow: CONNECT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
            bail!("not a CONNECT: {line:?}");
        }
        let Ok((host, port)) = split_authority(target) else {
            sock.write_all(
                b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await?;
            bail!("bad CONNECT target {target:?}");
        };

        if self.brokered(&host, port) {
            let route = async {
                match self
                    .exchange(&Request::Connect {
                        host: host.clone(),
                        port,
                    })
                    .await?
                {
                    (send, recv, Response::Connected) => Ok((send, recv)),
                    (_, _, Response::Refused { reason }) => Err(anyhow!("refused: {reason}")),
                    _ => Err(anyhow!("unexpected reply")),
                }
            };
            match route.await {
                Ok((mut send, recv)) => {
                    sock.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        .await?;
                    send.write_all(&leftover).await?;
                    let mut io = tokio::io::join(recv, send);
                    let _ = tokio::io::copy_bidirectional(&mut sock, &mut io).await;
                    Ok(())
                }
                Err(e) => {
                    let status: &[u8] = if e.to_string().starts_with("refused:") {
                        b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    } else {
                        b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    };
                    sock.write_all(status).await?;
                    Err(e.context(format!("brokered CONNECT {host}:{port}")))
                }
            }
        } else {
            let mut up = match dial::connect(&host, port).await {
                Ok(s) => s,
                Err(e) => {
                    sock.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
                    return Err(anyhow!(e)).context(format!("direct CONNECT {host}:{port}"));
                }
            };
            sock.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await?;
            up.write_all(&leftover).await?;
            let _ = tokio::io::copy_bidirectional(&mut sock, &mut up).await;
            Ok(())
        }
    }
}

/// Read up to the blank line ending a request head. Returns the head and any
/// bytes read past it (an eager client's first TLS flight).
async fn read_head(sock: &mut TcpStream) -> Result<(String, Vec<u8>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let leftover = buf.split_off(end + 4);
            return Ok((String::from_utf8_lossy(&buf).into_owned(), leftover));
        }
        if buf.len() > 16 * 1024 {
            bail!("request head too large");
        }
        let n = sock.read(&mut chunk).await?;
        if n == 0 {
            bail!("client closed before finishing its request");
        }
        buf.extend_from_slice(&chunk[..n]);
    }
}
