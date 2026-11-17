//! The broker proper: accept sandboxes over iroh, terminate TLS for allowed
//! hosts, and relay each HTTP/1.1 request through tokenizer, which injects the
//! credential and calls the upstream over HTTPS.
//!
//! Policy is looked up again for every request, so a reload revokes tunnels
//! that are already open, not only new ones.
//!
//! Nothing on a request path may panic on what a sandbox sends: no `unwrap`
//! and no `expect` after this point depends on attacker input.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError, RwLock, Weak};

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::header::{HeaderName, HeaderValue, HOST};
use hyper::http::uri::{Authority, PathAndQuery, Scheme};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioIo, TokioTimer};
use iroh::endpoint::{Connection, RecvStream, SendStream, VarInt};
use iroh::{Endpoint, EndpointId};
use tokio::net::TcpStream;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::timeout;
use tokio_rustls::TlsAcceptor;
use tracing::{debug, error, info, warn};
use yolo_broker_wire::{
    canonical_host, format_authority, read_frame, split_authority, write_frame, Admit,
    EndpointOpts, Host, Request as Ctl, Response as CtlReply, DEFAULT_PORT,
};
use zeroize::Zeroizing;

use crate::ca::Ca;
use crate::limits::{idle_watch, Limits, Tracked};
use crate::policy::{Policy, Rule};
use crate::store::{Snapshot, Store};

type Body = BoxBody<Bytes, hyper::Error>;

/// Close code for a connection from an endpoint the policy does not list.
const CLOSE_UNKNOWN: u32 = 403;

/// The only methods a sandbox may use. Anything else (TRACE, CONNECT, WebDAV,
/// a made-up token) is a 405.
const ALLOWED_METHODS: [Method; 7] = [
    Method::GET,
    Method::HEAD,
    Method::POST,
    Method::PUT,
    Method::PATCH,
    Method::DELETE,
    Method::OPTIONS,
];

/// One loaded generation of the store's contents. No `Debug`: it holds the
/// tokenizer password and the sealed secrets.
pub struct State {
    policy: Policy,
    secrets: HashMap<String, String>,
    /// `host:port` to dial for tokenizer (IPv6 bracketed).
    tokenizer_addr: String,
    password: Zeroizing<String>,
    ca: Ca,
}

/// The `host:port` to dial for a tokenizer URL `http://host[:port][/]`. IPv6
/// hosts are bracketed (`http://[::1]:8080`); the port defaults to 80.
pub fn tokenizer_addr(url: &str) -> Result<String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| anyhow!("tokenizer url must start with http://"))?
        .trim_end_matches('/');
    if rest.contains('@') {
        bail!("tokenizer url must not carry credentials");
    }
    let auth: Authority = rest.parse().context("tokenizer url")?;
    Ok(match auth.port_u16() {
        Some(_) => auth.as_str().to_string(),
        None => format!("{}:80", auth.host()),
    })
}

impl State {
    fn from_snapshot(s: Snapshot, limits: &Limits) -> Result<Self> {
        Ok(Self {
            ca: Ca::load_with(&s.ca_cert_pem, &s.ca_key_pem, limits.max_leaves)?,
            policy: s.policy,
            secrets: s.secrets,
            tokenizer_addr: tokenizer_addr(&s.tokenizer_url)?,
            password: s.tokenizer_password,
        })
    }
}

pub struct Broker<S> {
    store: S,
    state: RwLock<Arc<State>>,
    limits: Limits,
    global: Arc<Semaphore>,
    nodes: Mutex<HashMap<EndpointId, Arc<Semaphore>>>,
}

impl<S: Store> Broker<S> {
    /// Load the store. Fails if it cannot, so a broker never starts empty.
    pub async fn new(store: S) -> Result<Arc<Self>> {
        Self::with_limits(store, Limits::default()).await
    }

    pub async fn with_limits(store: S, limits: Limits) -> Result<Arc<Self>> {
        let state = State::from_snapshot(store.load().await?, &limits)?;
        Ok(Arc::new(Self {
            store,
            state: RwLock::new(Arc::new(state)),
            global: Arc::new(Semaphore::new(limits.max_streams)),
            nodes: Mutex::new(HashMap::new()),
            limits,
        }))
    }

    /// Reload the store. On failure the previous state stays in force and the
    /// error is returned; callers should log it loudly, since a failed reload
    /// means a revocation did not happen.
    pub async fn reload(&self) -> Result<()> {
        let state = State::from_snapshot(self.store.load().await?, &self.limits)?;
        *self.state.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(state);
        info!("reloaded store");
        Ok(())
    }

    fn state(&self) -> Arc<State> {
        self.state
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// The iroh endpoint settings the broker wants: its bind addresses (at
    /// most one per IP family), bi-stream cap, and a filter that drops
    /// endpoints the policy does not list right after the handshake. The
    /// filter holds the broker weakly, so it does not keep it alive.
    pub fn endpoint_opts(self: &Arc<Self>, bind: Vec<SocketAddr>) -> EndpointOpts {
        let weak: Weak<Self> = Arc::downgrade(self);
        let admit: Admit = Arc::new(move |node: &EndpointId| {
            let known = weak.upgrade().is_some_and(|b| b.state().policy.knows(node));
            if !known {
                warn!(target: "audit", node = %node, event = "refused", reason = "unknown endpoint");
            }
            known
        });
        EndpointOpts {
            bind,
            max_bidi_streams: Some(
                self.limits
                    .max_streams_per_node
                    .try_into()
                    .unwrap_or(u32::MAX),
            ),
            admit: Some(admit),
        }
    }

    /// Accept sandboxes until the endpoint closes.
    pub async fn serve(self: Arc<Self>, endpoint: Endpoint) {
        while let Some(incoming) = endpoint.accept().await {
            let this = self.clone();
            tokio::spawn(async move {
                match incoming.await {
                    Ok(conn) => this.connection(conn).await,
                    Err(e) => debug!("handshake failed: {e}"),
                }
            });
        }
    }

    async fn connection(self: Arc<Self>, conn: Connection) {
        let node = conn.remote_id();
        // The endpoint's filter already dropped strangers; this is the second lock.
        if !self.state().policy.knows(&node) {
            warn!(target: "audit", node = %node, event = "refused", reason = "unknown endpoint");
            conn.close(VarInt::from_u32(CLOSE_UNKNOWN), b"unknown endpoint");
            return;
        }
        debug!(node = %node, "sandbox connected");
        while let Ok((send, recv)) = conn.accept_bi().await {
            let this = self.clone();
            tokio::spawn(async move {
                if let Err(e) = this.stream(node, send, recv).await {
                    debug!(node = %node, "stream ended: {e:#}");
                }
            });
        }
    }

    /// A slot for one stream: one from the global pool and one from `node`'s.
    fn permits(&self, node: &EndpointId) -> Option<(OwnedSemaphorePermit, OwnedSemaphorePermit)> {
        let global = self.global.clone().try_acquire_owned().ok()?;
        let mine = self
            .nodes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(*node)
            .or_insert_with(|| Arc::new(Semaphore::new(self.limits.max_streams_per_node)))
            .clone();
        Some((global, mine.try_acquire_owned().ok()?))
    }

    async fn stream(
        self: Arc<Self>,
        node: EndpointId,
        mut send: SendStream,
        mut recv: RecvStream,
    ) -> Result<()> {
        let Some(_permits) = self.permits(&node) else {
            return refuse(&mut send, node, None, "too many open streams").await;
        };
        let req: Ctl = timeout(self.limits.control_read, read_frame(&mut recv))
            .await
            .map_err(|_| anyhow!("timed out waiting for the control frame"))??;
        let state = self.state();
        match req {
            Ctl::Policy => {
                let Some(hosts) = state.policy.patterns(&node) else {
                    return refuse(&mut send, node, None, "unknown endpoint").await;
                };
                write_frame(&mut send, &CtlReply::Policy { hosts }).await?;
                send.finish()?;
                Ok(())
            }
            Ctl::Connect { host, port } => {
                // Nothing the sandbox sent is used, logged or looked up before
                // it is a validated host.
                let Ok(host) = canonical_host(&host) else {
                    return refuse(&mut send, node, None, "bad host").await;
                };
                if port == 0 {
                    return refuse(&mut send, node, None, "bad port").await;
                }
                let at = Some((host.as_str(), port));
                let Some(rule) = state.policy.lookup(&node, &host, port) else {
                    return refuse(&mut send, node, at, "host not in policy").await;
                };
                if !state.secrets.contains_key(&rule.secret) {
                    return refuse(&mut send, node, at, "secret missing").await;
                }
                // Key generation is CPU work: keep it off the async threads.
                let tls = {
                    let (state, host) = (state.clone(), host.clone());
                    tokio::task::spawn_blocking(move || state.ca.server_config(&host))
                        .await
                        .context("minting task")??
                };
                write_frame(&mut send, &CtlReply::Connected).await?;
                let (io, activity) = Tracked::new(tokio::io::join(recv, send));
                let tls = timeout(self.limits.tls_accept, TlsAcceptor::from(tls).accept(io))
                    .await
                    .map_err(|_| anyhow!("timed out in the tls handshake with the sandbox"))?
                    .context("tls handshake with sandbox")?;
                let tunnel = Arc::new(Tunnel {
                    broker: self.clone(),
                    node,
                    host,
                    port,
                });
                let svc = service_fn(move |req| {
                    let tunnel = tunnel.clone();
                    async move { Ok::<_, Infallible>(tunnel.request(req).await) }
                });
                let conn = hyper::server::conn::http1::Builder::new()
                    .timer(TokioTimer::new())
                    .header_read_timeout(self.limits.header_read)
                    .max_buf_size(64 * 1024)
                    .max_headers(100)
                    .serve_connection(TokioIo::new(tls), svc);
                tokio::select! {
                    r = conn => r.context("serving sandbox")?,
                    _ = idle_watch(activity, self.limits.idle) => bail!("tunnel idle too long"),
                }
                Ok(())
            }
        }
    }
}

/// Tell the sandbox no, and say so in the audit log. `host` is logged only
/// when it has been validated; a host that did not validate never reaches a
/// log line, so it cannot forge one.
async fn refuse(
    send: &mut SendStream,
    node: EndpointId,
    host: Option<(&str, u16)>,
    reason: &str,
) -> Result<()> {
    let (h, port) = host.unwrap_or(("-", 0));
    warn!(target: "audit", node = %node, host = %h, port, event = "refused", reason);
    write_frame(
        send,
        &CtlReply::Refused {
            reason: reason.into(),
        },
    )
    .await?;
    send.finish()?;
    Ok(())
}

/// One TLS-terminated CONNECT from one sandbox to one host.
struct Tunnel<S> {
    broker: Arc<Broker<S>>,
    node: EndpointId,
    /// Validated and canonical: lowercase DNS name or unbracketed IP.
    host: String,
    port: u16,
}

const HOP_BY_HOP: [&str; 8] = [
    "connection",
    "keep-alive",
    "proxy-connection",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "upgrade",
];

fn text(status: StatusCode, msg: &'static str) -> Response<Body> {
    let mut r = Response::new(
        Full::new(Bytes::from_static(msg.as_bytes()))
            .map_err(|e| match e {})
            .boxed(),
    );
    *r.status_mut() = status;
    r
}

/// The `host[:port]` a request names to tokenizer, IPv6 bracketed. Tokenizer
/// dials 443 for a port-less (or :80) URL and refuses an explicit :443.
pub fn upstream_authority(host: &str, port: u16) -> String {
    if port == DEFAULT_PORT {
        Host::parse(host).map_or_else(|_| host.to_string(), |h| h.bracketed())
    } else {
        format_authority(host, port)
    }
}

type Reject = (StatusCode, &'static str);

/// The plain-HTTP URI tokenizer gets: built from parts, never by pasting
/// strings together, then checked: its authority must be exactly the validated
/// host (and port), nothing else.
pub fn upstream_uri(host: &str, port: u16, path_and_query: &str) -> Result<Uri, Reject> {
    let bad = |m: &'static str| (StatusCode::BAD_REQUEST, m);
    let want = Host::parse(host).map_err(|_| bad("bad host\n"))?;
    let text = upstream_authority(host, port);
    let authority: Authority = text.parse().map_err(|_| bad("bad host\n"))?;
    if !path_and_query.starts_with('/') {
        return Err(bad("bad request target\n"));
    }
    let pq: PathAndQuery = path_and_query
        .parse()
        .map_err(|_| bad("bad request target\n"))?;
    let uri = Uri::builder()
        .scheme(Scheme::HTTP)
        .authority(authority)
        .path_and_query(pq)
        .build()
        .map_err(|_| bad("bad request target\n"))?;
    let built = uri.authority().ok_or(bad("bad host\n"))?;
    let same = built.as_str() == text
        && Host::parse(built.host()).is_ok_and(|h| h == want)
        && built.port_u16().unwrap_or(DEFAULT_PORT) == port;
    if !same {
        return Err(bad("bad host\n"));
    }
    Ok(uri)
}

/// Origin-form (`/path?q`), or absolute-form naming this tunnel's own host
/// over https. Everything else is refused: `*` (so `OPTIONS *`), authority-form,
/// another host, another scheme.
fn request_target<'a>(uri: &'a Uri, host: &str, port: u16) -> Result<&'a str, Reject> {
    let bad = |m: &'static str| (StatusCode::BAD_REQUEST, m);
    match (uri.scheme(), uri.authority()) {
        (None, None) => {
            let pq = uri.path_and_query().map_or("", |p| p.as_str());
            if pq.starts_with('/') {
                Ok(pq)
            } else {
                Err(bad("unsupported request target\n"))
            }
        }
        (Some(s), Some(a)) if *s == Scheme::HTTPS => {
            match split_authority(a.as_str()) {
                Ok((h, p)) if h == host && p == port => {}
                _ => {
                    return Err((
                        StatusCode::MISDIRECTED_REQUEST,
                        "request target does not match the tunnel\n",
                    ))
                }
            }
            Ok(uri.path_and_query().map_or("/", |p| p.as_str()))
        }
        _ => Err(bad("unsupported request target\n")),
    }
}

impl<S: Store> Tunnel<S> {
    async fn request(&self, req: Request<Incoming>) -> Response<Body> {
        let method = req.method().to_string();
        let path = req.uri().path().to_string();
        let (status, resp) = match self.forward(req).await {
            Ok(r) => (r.status(), r),
            Err((status, msg)) => (status, text(status, msg)),
        };
        info!(target: "audit", node = %self.node, host = %self.host, port = self.port,
            method = %method, path = %path, status = status.as_u16());
        resp
    }

    async fn forward(&self, req: Request<Incoming>) -> Result<Response<Body>, Reject> {
        if !ALLOWED_METHODS.contains(req.method()) {
            return Err((StatusCode::METHOD_NOT_ALLOWED, "method not allowed\n"));
        }
        let pq = request_target(req.uri(), &self.host, self.port)?.to_string();

        // The Host header must be the host the tunnel was admitted for;
        // otherwise a client could ask tokenizer to use this host's secret
        // for another one. (Tokenizer's allowed_hosts check is the second lock.)
        let mut hosts = req.headers().get_all(HOST).iter();
        let host_hdr = match (hosts.next(), hosts.next()) {
            (Some(h), None) => h.to_str().ok(),
            (None, _) => return Err((StatusCode::BAD_REQUEST, "missing Host header\n")),
            _ => return Err((StatusCode::BAD_REQUEST, "more than one Host header\n")),
        };
        match host_hdr.map(split_authority) {
            Some(Ok((h, p))) if h == self.host && p == self.port => {}
            _ => {
                return Err((
                    StatusCode::MISDIRECTED_REQUEST,
                    "Host does not match the tunnel\n",
                ))
            }
        }

        let state = self.broker.state();
        let rule: &Rule = state
            .policy
            .lookup(&self.node, &self.host, self.port)
            .ok_or((StatusCode::FORBIDDEN, "not permitted by policy\n"))?;
        let sealed = state
            .secrets
            .get(&rule.secret)
            .ok_or((StatusCode::FORBIDDEN, "secret missing\n"))?;

        let uri = upstream_uri(&self.host, self.port, &pq)?;
        let authority = upstream_authority(&self.host, self.port);
        let (parts, body) = req.into_parts();
        let mut out = Request::new(body);
        *out.method_mut() = parts.method;
        *out.uri_mut() = uri;
        *out.version_mut() = hyper::Version::HTTP_11;
        let headers = out.headers_mut();
        for (name, value) in &parts.headers {
            let n = name.as_str();
            // Framing is hyper's job: the client's content-length and
            // transfer-encoding are dropped, and hyper sets its own from the
            // body it forwards.
            if n == "host"
                || n == "transfer-encoding"
                || n == "content-length"
                || n.starts_with("proxy-")
                || HOP_BY_HOP.contains(&n)
            {
                continue;
            }
            headers.append(name.clone(), value.clone());
        }
        headers.insert(
            HOST,
            HeaderValue::from_str(&authority)
                .map_err(|_| (StatusCode::BAD_REQUEST, "bad host\n"))?,
        );
        let mut tk = sealed.clone();
        if !rule.params.is_empty() {
            tk.push_str("; ");
            tk.push_str(
                &serde_json::to_string(&rule.params)
                    .map_err(|_| (StatusCode::BAD_GATEWAY, "bad rule parameters\n"))?,
            );
        }
        let mut tk =
            HeaderValue::from_str(&tk).map_err(|_| (StatusCode::BAD_GATEWAY, "bad secret\n"))?;
        tk.set_sensitive(true);
        let mut auth = HeaderValue::from_str(&format!("Bearer {}", state.password.as_str()))
            .map_err(|_| (StatusCode::BAD_GATEWAY, "bad password\n"))?;
        auth.set_sensitive(true);
        headers.insert(HeaderName::from_static("proxy-tokenizer"), tk);
        headers.insert(HeaderName::from_static("proxy-authorization"), auth);

        let resp = send_to_tokenizer(&state.tokenizer_addr, out, &self.broker.limits)
            .await
            .map_err(|e| {
                error!("tokenizer: {e:#}");
                (StatusCode::BAD_GATEWAY, "tokenizer unavailable\n")
            })?;

        let (mut parts, body) = resp.into_parts();
        let drop: Vec<HeaderName> = parts
            .headers
            .keys()
            .filter(|k| {
                k.as_str() == "transfer-encoding"
                    || k.as_str().starts_with("proxy-")
                    || HOP_BY_HOP.contains(&k.as_str())
            })
            .cloned()
            .collect();
        for k in drop {
            parts.headers.remove(k);
        }
        Ok(Response::from_parts(parts, body.boxed()))
    }
}

/// One plain-HTTP request to tokenizer on a fresh connection (tokenizer
/// answers `Connection: close`, so there is nothing to reuse), with a timeout
/// on connecting and another on getting the response headers.
async fn send_to_tokenizer(
    addr: &str,
    req: Request<Incoming>,
    limits: &Limits,
) -> Result<Response<Incoming>> {
    let tcp = timeout(limits.tokenizer_connect, TcpStream::connect(addr))
        .await
        .map_err(|_| anyhow!("timed out connecting to {addr}"))?
        .with_context(|| format!("connect {addr}"))?;
    let (mut sender, conn) = timeout(
        limits.tokenizer_connect,
        hyper::client::conn::http1::handshake(TokioIo::new(tcp)),
    )
    .await
    .map_err(|_| anyhow!("timed out in the http handshake with {addr}"))??;
    tokio::spawn(async move {
        let _ = conn.await;
    });
    timeout(limits.tokenizer_request, sender.send_request(req))
        .await
        .map_err(|_| {
            anyhow!(
                "tokenizer did not answer within {:?}",
                limits.tokenizer_request
            )
        })?
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenizer_urls() {
        for (url, want) in [
            ("http://127.0.0.1:8080", "127.0.0.1:8080"),
            ("http://127.0.0.1:8080/", "127.0.0.1:8080"),
            ("http://127.0.0.1", "127.0.0.1:80"),
            ("http://localhost:9", "localhost:9"),
            ("http://tokenizer.internal", "tokenizer.internal:80"),
            ("http://[::1]:8080", "[::1]:8080"),
            ("http://[::1]", "[::1]:80"),
            ("http://[::1]/", "[::1]:80"),
            ("http://[2001:db8::1]:8080/", "[2001:db8::1]:8080"),
        ] {
            assert_eq!(tokenizer_addr(url).unwrap(), want, "{url}");
        }
        for bad in [
            "https://a:1",
            "a:1",
            "http://",
            "http://u@a:1",
            "http://a:1/x",
            "http://[::1",
        ] {
            assert!(tokenizer_addr(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn upstream_authorities() {
        assert_eq!(upstream_authority("a.test", 443), "a.test");
        assert_eq!(upstream_authority("a.test", 8443), "a.test:8443");
        assert_eq!(upstream_authority("::1", 443), "[::1]");
        assert_eq!(upstream_authority("::1", 8443), "[::1]:8443");
        assert_eq!(upstream_authority("192.0.2.1", 8443), "192.0.2.1:8443");
    }

    #[test]
    fn the_uri_is_built_from_parts_and_checked() {
        let uri = upstream_uri("api.example.com", 443, "/v1/x?y=1").unwrap();
        assert_eq!(uri.to_string(), "http://api.example.com/v1/x?y=1");
        let uri = upstream_uri("::1", 8443, "/p").unwrap();
        assert_eq!(uri.to_string(), "http://[::1]:8443/p");
        assert_eq!(uri.authority().unwrap().host(), "[::1]");
        // A path that looks like an authority stays a path.
        let uri = upstream_uri("a.test", 443, "//evil.test/x").unwrap();
        assert_eq!(uri.authority().unwrap().as_str(), "a.test");
        assert_eq!(uri.path(), "//evil.test/x");

        // The old format!("http://{authority}{pq}") re-parsed `evil.com?.example.com`
        // as authority `evil.com`. Now it never gets built.
        for host in [
            "evil.com?.example.com",
            "evil.com#.example.com",
            "evil.com@x.example.com",
            "a b",
            "",
            "evil.com/x",
        ] {
            assert!(upstream_uri(host, 443, "/").is_err(), "{host:?}");
        }
        for pq in ["", "*", "evil.test/x", "x", "/a b"] {
            assert!(upstream_uri("a.test", 443, pq).is_err(), "{pq:?}");
        }
    }

    #[test]
    fn request_targets() {
        let t = |s: &str| {
            let uri: Uri = s.parse().unwrap();
            request_target(&uri, "a.test", 443).map(str::to_string)
        };
        assert_eq!(t("/x?y").unwrap(), "/x?y");
        assert_eq!(t("/").unwrap(), "/");
        assert_eq!(t("https://a.test/x").unwrap(), "/x");
        assert_eq!(t("https://A.test:443/x").unwrap(), "/x");
        assert_eq!(t("https://a.test").unwrap(), "/");
        assert_eq!(
            t("https://b.test/x").unwrap_err().0,
            StatusCode::MISDIRECTED_REQUEST
        );
        assert_eq!(
            t("https://a.test:8443/x").unwrap_err().0,
            StatusCode::MISDIRECTED_REQUEST
        );
        assert_eq!(t("http://a.test/x").unwrap_err().0, StatusCode::BAD_REQUEST);
        assert_eq!(t("*").unwrap_err().0, StatusCode::BAD_REQUEST);
        assert_eq!(t("a.test:443").unwrap_err().0, StatusCode::BAD_REQUEST);
    }

    #[test]
    fn only_the_listed_methods() {
        for m in ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
            assert!(
                ALLOWED_METHODS.contains(&m.parse::<Method>().unwrap()),
                "{m}"
            );
        }
        for m in ["TRACE", "CONNECT", "PROPFIND", "LINK", "get", "FOO"] {
            assert!(
                !ALLOWED_METHODS.contains(&m.parse::<Method>().unwrap()),
                "{m}"
            );
        }
    }
}
