//! End to end: a real tokenizer process, the real `yolo-broker` binary, a fake
//! HTTPS upstream with its own CA, and the sandbox proxy dialing over iroh
//! (relays off, direct loopback addresses). Nothing leaves localhost.
//!
//! These need the tokenizer binaries, which the flake provides:
//! `TOKENIZER_BIN` (stock `tokenizer`) and `TOKENIZER_TEST_BIN` (the same
//! library behind a main that may dial loopback). Without them the tests print
//! SKIPPED and pass, so plain `cargo test` outside `nix develop` stays green.

use std::net::{SocketAddr, UdpSocket};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use iroh::{EndpointAddr, EndpointId, SecretKey};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, Command};
use yolo_broker::ca::{generate_ca, Ca};
use yolo_broker::seal;
use yolo_broker::store::FileStore;
use yolo_broker_proxy::{start, Config, Proxy};
use yolo_broker_wire::{
    bind_endpoint, format_authority, read_frame, write_frame, EndpointOpts, Network,
    Request as Ctl, Response as CtlReply, ALPN,
};

const TOKEN: &str = "tok-SECRET-0123456789";

// ------------------------------------------------------------------ helpers

struct Bins {
    stock: PathBuf,
    test: PathBuf,
}

fn bins() -> Option<Bins> {
    match (
        std::env::var("TOKENIZER_BIN"),
        std::env::var("TOKENIZER_TEST_BIN"),
    ) {
        (Ok(stock), Ok(test)) => Some(Bins {
            stock: stock.into(),
            test: test.into(),
        }),
        _ => {
            eprintln!("SKIPPED: TOKENIZER_BIN and TOKENIZER_TEST_BIN are not set (run inside `nix develop` in broker/)");
            None
        }
    }
}

fn sha256_hex(s: &str) -> String {
    yolo_broker_wire::hex(&Sha256::digest(s.as_bytes()))
}

fn free_udp_port() -> u16 {
    UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn free_udp_port6() -> u16 {
    UdpSocket::bind("[::1]:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Does this host have a usable `::1`? IPv6 tests say SKIPPED and pass if not.
fn has_v6() -> bool {
    UdpSocket::bind("[::1]:0").is_ok() && std::net::TcpListener::bind("[::1]:0").is_ok()
}

/// A name that resolves to `::1` on this host, if any: `localhost` does on
/// most, `ip6-localhost` on Debian-style /etc/hosts. Tests that need a name for
/// an IPv6-only upstream use it, and skip when there is none.
fn v6_loopback_name() -> Option<&'static str> {
    use std::net::ToSocketAddrs;
    ["localhost", "ip6-localhost", "ip6-loopback"]
        .into_iter()
        .find(|n| {
            (*n, 1)
                .to_socket_addrs()
                .is_ok_and(|mut a| a.any(|a| a.ip().is_loopback() && a.is_ipv6()))
        })
}

macro_rules! need_v6_name {
    () => {
        match v6_loopback_name() {
            Some(n) => n,
            None => {
                eprintln!("SKIPPED: no host name on this machine resolves to ::1");
                return;
            }
        }
    };
}

macro_rules! need_v6 {
    () => {
        if !has_v6() {
            eprintln!("SKIPPED: this host has no ::1");
            return;
        }
    };
}

/// How the sandbox proxy and the broker reach each other over iroh.
#[derive(Clone, Copy, PartialEq)]
enum Net {
    /// The broker binds IPv4 loopback, and IPv6 loopback when the host has it;
    /// the proxy is told both addresses.
    Both,
    /// The broker binds IPv6 loopback, and the proxy is told only that.
    V6Only,
}

type Logs = Arc<Mutex<Vec<String>>>;

/// Collect a child's stderr lines; returns once `ready` matches a line.
async fn watch_stderr(child: &mut Child, ready: &str) -> Logs {
    let ready_for_msg = ready.to_string();
    let stderr = child.stderr.take().unwrap();
    let logs: Logs = Arc::default();
    let sink = logs.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        while let Ok(Some(l)) = lines.next_line().await {
            sink.lock().unwrap().push(l);
        }
    });
    wait_for(&logs, |l| l.contains(ready), 0, &ready_for_msg).await;
    logs
}

async fn wait_for(logs: &Logs, pred: impl Fn(&str) -> bool, skip: usize, what: &str) -> String {
    for _ in 0..200 {
        if let Some(l) = logs.lock().unwrap().iter().skip(skip).find(|l| pred(l)) {
            return l.clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!(
        "timed out waiting for {what}; have:\n{}",
        logs.lock().unwrap().join("\n")
    );
}

fn client_tls(ca_pem: &str) -> tokio_rustls::TlsConnector {
    let mut roots = rustls::RootCertStore::empty();
    for c in CertificateDer::pem_slice_iter(ca_pem.as_bytes()) {
        roots.add(c.unwrap()).unwrap();
    }
    let mut cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    tokio_rustls::TlsConnector::from(Arc::new(cfg))
}

// ------------------------------------------------------------ fake upstream

/// HTTPS server on `bind`, for the name `cert_host`, signed by its own CA. It
/// never reveals the credential it receives: it echoes the SHA-256 of the
/// Authorization header, so a test can prove the right value arrived while the
/// sandbox can never have seen the plaintext. It also echoes how the request
/// was framed and the length of its body.
async fn fake_upstream(ca: &Ca, bind: &str, cert_host: &str) -> u16 {
    let listener = TcpListener::bind(bind).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let acceptor = tokio_rustls::TlsAcceptor::from(ca.server_config(cert_host).unwrap());
    tokio::spawn(async move {
        loop {
            let (sock, _) = listener.accept().await.unwrap();
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(tls) = acceptor.accept(sock).await else {
                    return;
                };
                let svc = service_fn(|req: Request<Incoming>| async move {
                    let h = |n: &str| {
                        req.headers()
                            .get(n)
                            .and_then(|v| v.to_str().ok())
                            .map(str::to_owned)
                    };
                    let mut body = json!({
                        "authorization_sha256": h("authorization").map(|a| sha256_hex(&a)),
                        "saw_proxy_headers": req.headers().keys().any(|k| k.as_str().starts_with("proxy-")),
                        "host": h("host"),
                        "method": req.method().as_str(),
                        "path": req.uri().path(),
                        "user_agent": h("user-agent"),
                        "content_length": h("content-length"),
                        "transfer_encoding": h("transfer-encoding"),
                    });
                    let got = req.into_body().collect().await.map(|b| b.to_bytes());
                    body["body_len"] = json!(got.as_ref().map(|b| b.len()).unwrap_or(0));
                    Ok::<_, std::convert::Infallible>(
                        Response::builder()
                            .header("x-upstream", "fake")
                            .body(Full::new(Bytes::from(body.to_string())))
                            .unwrap(),
                    )
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(tls), svc)
                    .await;
            });
        }
    });
    port
}

// ------------------------------------------------------------------- world

struct BrokerProc {
    child: Child,
    logs: Logs,
}

struct World {
    tmp: tempfile::TempDir,
    store: FileStore,
    upstream_port: u16,
    /// The CA tokenizer trusts upstreams under.
    up_ca: Arc<Ca>,
    _tokenizer: Child,
    seal_key: String,
    sandbox_key: SecretKey,
    broker_id: EndpointId,
    /// The broker's addresses as the proxy is told them.
    broker_addrs: Vec<SocketAddr>,
    /// What the broker binds (`--bind`).
    broker_binds: Vec<SocketAddr>,
    broker: Option<BrokerProc>,
    proxy: Option<Proxy>,
}

impl World {
    /// Everything up: tokenizer, upstream, store with one sealed secret and a
    /// policy letting the sandbox reach the upstream, broker, sandbox proxy.
    async fn new(bins: &Bins) -> World {
        World::new_on(bins, Net::Both).await
    }

    async fn new_on(bins: &Bins, net: Net) -> World {
        // Set RUST_LOG (say, yolo_broker_proxy=debug) to see the proxy's side.
        let _ = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .with_test_writer()
            .try_init();
        let tmp = tempfile::tempdir().unwrap();

        // The upstream's CA, which tokenizer must trust (Go reads SSL_CERT_FILE).
        let (up_cert, up_key) = generate_ca("fake upstream CA").unwrap();
        let up_ca = Ca::load(&up_cert, &up_key).unwrap();
        let up_ca = Arc::new(up_ca);
        let upstream_port = fake_upstream(&up_ca, "127.0.0.1:0", "localhost").await;
        let up_ca_file = tmp.path().join("upstream-ca.pem");
        std::fs::write(&up_ca_file, &up_cert).unwrap();

        let open_key = yolo_broker_wire::hex(&SecretKey::generate().to_bytes());
        let mut tokenizer = Command::new(&bins.test)
            .env("OPEN_KEY", open_key)
            .env("LISTEN_ADDRESS", "127.0.0.1:0")
            .env("SSL_CERT_FILE", &up_ca_file)
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let tk_logs = watch_stderr(&mut tokenizer, "seal_key=").await;
        let line = tk_logs
            .lock()
            .unwrap()
            .iter()
            .find(|l| l.contains("seal_key="))
            .unwrap()
            .clone();
        let field = |name: &str| {
            line.split(&format!("{name}="))
                .nth(1)
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .to_string()
        };
        let tk_addr = field("address");
        let seal_key = field("seal_key");

        let store = FileStore::new(tmp.path().join("store"));
        store.init(&format!("http://{tk_addr}")).unwrap();

        let sandbox_key = SecretKey::generate();
        let (broker_addrs, broker_binds): (Vec<SocketAddr>, Vec<SocketAddr>) = match net {
            Net::Both => {
                let v4: SocketAddr = ([127, 0, 0, 1], free_udp_port()).into();
                if has_v6() {
                    let v6: SocketAddr = format!("[::1]:{}", free_udp_port6()).parse().unwrap();
                    (vec![v4, v6], vec![v4, v6])
                } else {
                    (vec![v4], vec![v4])
                }
            }
            Net::V6Only => {
                let v6: SocketAddr = format!("[::1]:{}", free_udp_port6()).parse().unwrap();
                (vec![v6], vec![v6])
            }
        };
        let w = World {
            tmp,
            store,
            upstream_port,
            up_ca,
            _tokenizer: tokenizer,
            seal_key,
            sandbox_key,
            broker_id: SecretKey::generate().public(),
            broker_addrs,
            broker_binds,
            broker: None,
            proxy: None,
        };
        w.seal_secret("up", TOKEN, &format!("localhost:{upstream_port}"));
        w.write_policy(true);
        w
    }

    fn seal_secret(&self, id: &str, token: &str, allowed_host: &str) {
        let json =
            json!({ "inject_processor": { "token": token }, "allowed_hosts": [allowed_host] });
        let prepared = seal::prepare_secret(
            &json.to_string(),
            Some(self.store.read_password().unwrap().as_str()),
        )
        .unwrap();
        self.store
            .put_secret(id, &seal::seal(&self.seal_key, &prepared).unwrap())
            .unwrap();
    }

    fn write_policy(&self, allow_upstream: bool) {
        let rules = if allow_upstream {
            vec![(
                format!("localhost:{}", self.upstream_port),
                "up".to_string(),
            )]
        } else {
            vec![]
        };
        self.write_rules(&rules);
    }

    /// The sandbox's whole policy: (host pattern, secret id) rules.
    fn write_rules(&self, rules: &[(String, String)]) {
        let rules = if rules.is_empty() {
            String::new()
        } else {
            let each: Vec<String> = rules
                .iter()
                .map(|(h, s)| format!("{{ host = \"{h}\", secret = \"{s}\" }}"))
                .collect();
            format!("rules = [{}]", each.join(", "))
        };
        std::fs::write(
            self.store.dir().join("policy.toml"),
            format!(
                "[[sandbox]]\nid = \"{}\"\nname = \"test sandbox\"\n{rules}\n",
                self.sandbox_key.public()
            ),
        )
        .unwrap();
    }

    fn key_file(&self) -> PathBuf {
        self.tmp.path().join("broker.key")
    }

    async fn start_broker(&mut self) {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_yolo-broker"));
        cmd.args(["serve", "--direct", "--log-format", "json"]);
        for b in &self.broker_binds {
            cmd.arg("--bind").arg(b.to_string());
        }
        let mut child = cmd
            .arg("--store")
            .arg(self.store.dir())
            .arg("--key-file")
            .arg(self.key_file())
            .env("RUST_LOG", "info")
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let logs = watch_stderr(&mut child, "\"listening\"").await;
        let id = Command::new(env!("CARGO_BIN_EXE_yolo-broker"))
            .args(["id", "--key-file"])
            .arg(self.key_file())
            .output()
            .await
            .unwrap();
        self.broker_id = String::from_utf8(id.stdout)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        self.broker = Some(BrokerProc { child, logs });
    }

    /// SIGKILL: the broker does not get to say goodbye.
    async fn crash_broker(&mut self) {
        let mut b = self.broker.take().unwrap();
        b.child.kill().await.unwrap();
    }

    fn logs(&self) -> Logs {
        self.broker.as_ref().unwrap().logs.clone()
    }

    /// SIGHUP, then wait for the broker to say it reloaded.
    async fn reload(&self) {
        let b = self.broker.as_ref().unwrap();
        let seen = b
            .logs
            .lock()
            .unwrap()
            .iter()
            .filter(|l| l.contains("reloaded store"))
            .count();
        let pid = b.child.id().unwrap().to_string();
        assert!(std::process::Command::new("kill")
            .args(["-HUP", &pid])
            .status()
            .unwrap()
            .success());
        for _ in 0..200 {
            if b.logs
                .lock()
                .unwrap()
                .iter()
                .filter(|l| l.contains("reloaded store"))
                .count()
                > seen
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("broker did not reload");
    }

    async fn start_proxy(&mut self) {
        let broker = self
            .broker_addrs
            .iter()
            .fold(EndpointAddr::new(self.broker_id), |a, s| a.with_ip_addr(*s));
        let proxy = start(Config {
            secret: self.sandbox_key.clone(),
            broker,
            network: Network::Direct,
            listen: self.local_addrs(),
            listen_is_default: false,
            bind: self.local_addrs(),
            refresh: Duration::from_millis(500),
            rpc_timeout: Duration::from_secs(3),
        })
        .await
        .unwrap();
        self.proxy = Some(proxy);
    }

    /// Loopback, port 0: IPv4 always, IPv6 when the host has it.
    fn local_addrs(&self) -> Vec<SocketAddr> {
        let mut v = vec![([127, 0, 0, 1], 0).into()];
        if has_v6() {
            v.push("[::1]:0".parse().unwrap());
        }
        v
    }

    /// The proxy's IPv6 listener.
    fn proxy_addr6(&self) -> SocketAddr {
        *self
            .proxy
            .as_ref()
            .unwrap()
            .local_addrs
            .iter()
            .find(|a| a.is_ipv6())
            .expect("a proxy listening on ::1")
    }

    fn proxy_addr(&self) -> SocketAddr {
        self.proxy.as_ref().unwrap().local_addr
    }

    fn broker_ca_pem(&self) -> String {
        std::fs::read_to_string(self.store.dir().join("ca.pem")).unwrap()
    }

    async fn open_tunnel(&self, host: &str, port: u16) -> Result<Tunnel, String> {
        open_tunnel(self.proxy_addr(), host, port, &self.broker_ca_pem()).await
    }

    /// Wait until the proxy has learned exactly these patterns.
    async fn wait_patterns(&self, want: &[String]) {
        let proxy = self.proxy.as_ref().unwrap();
        for _ in 0..200 {
            if proxy.patterns() == want {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("proxy has {:?}, wanted {want:?}", proxy.patterns());
    }

    /// Raw control exchange with the broker as an arbitrary endpoint.
    async fn raw(&self, key: SecretKey, req: &Ctl) -> anyhow::Result<CtlReply> {
        let ep = bind_endpoint(
            key,
            Network::Direct,
            vec![],
            EndpointOpts::bind(self.local_addrs()),
        )
        .await?;
        let addr = self
            .broker_addrs
            .iter()
            .fold(EndpointAddr::new(self.broker_id), |a, s| a.with_ip_addr(*s));
        let conn = ep.connect(addr, ALPN).await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, req).await?;
        let r = tokio::time::timeout(Duration::from_secs(5), read_frame(&mut recv)).await??;
        Ok(r)
    }

    async fn ready(bins: Bins) -> World {
        let mut w = World::new(&bins).await;
        w.start_broker().await;
        w.start_proxy().await;
        w
    }
}

// ------------------------------------------------------------------ client

struct Tunnel {
    sender: hyper::client::conn::http1::SendRequest<Full<Bytes>>,
}

/// What a sandbox process does: CONNECT through the local proxy, TLS with the
/// broker's CA as the only trust root, then HTTP/1.1. Err is the proxy's
/// non-200 status line.
async fn open_tunnel(
    proxy: SocketAddr,
    host: &str,
    port: u16,
    trust: &str,
) -> Result<Tunnel, String> {
    let mut sock = TcpStream::connect(proxy).await.unwrap();
    let authority = format_authority(host, port);
    sock.write_all(format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        let mut b = [0u8; 1];
        if sock.read(&mut b).await.unwrap() == 0 {
            break;
        }
        head.push(b[0]);
    }
    let head = String::from_utf8_lossy(&head).into_owned();
    let status = head.lines().next().unwrap_or("").to_string();
    if !status.contains(" 200 ") {
        return Err(status);
    }
    let name = ServerName::try_from(host.to_string()).unwrap();
    let tls = client_tls(trust)
        .connect(name, sock)
        .await
        .map_err(|e| format!("tls: {e}"))?;
    let (sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(tls))
        .await
        .unwrap();
    tokio::spawn(conn);
    Ok(Tunnel { sender })
}

struct Reply {
    status: StatusCode,
    headers: String,
    body: String,
}

impl Tunnel {
    async fn get(&mut self, host: &str, port: u16, path: &str, extra: &[(&str, &str)]) -> Reply {
        self.send("GET", host, port, path, extra, Bytes::new())
            .await
    }

    async fn send(
        &mut self,
        method: &str,
        host: &str,
        port: u16,
        path: &str,
        extra: &[(&str, &str)],
        body: Bytes,
    ) -> Reply {
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header("host", format_authority(host, port))
            .header("user-agent", "sandbox-test");
        for (k, v) in extra {
            req = req.header(*k, *v);
        }
        let resp = self
            .sender
            .send_request(req.body(Full::new(body)).unwrap())
            .await
            .unwrap();
        let (parts, body) = resp.into_parts();
        let body = String::from_utf8(body.collect().await.unwrap().to_bytes().to_vec()).unwrap();
        Reply {
            status: parts.status,
            headers: format!("{:?}", parts.headers),
            body,
        }
    }
}

fn json_body(r: &Reply) -> Value {
    serde_json::from_str(&r.body).unwrap_or_else(|_| panic!("not JSON: {}", r.body))
}

// ------------------------------------------------------------------- tests

#[tokio::test]
async fn allowed_host_gets_the_credential_and_the_sandbox_never_sees_it() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();

    // The sandbox sends no credential of its own, and tries to smuggle in
    // proxy headers the broker must not pass on.
    let sent: &[(&str, &str)] = &[
        ("proxy-tokenizer", "bogus"),
        ("proxy-authorization", "Bearer bogus"),
    ];
    assert!(sent
        .iter()
        .all(|(k, _)| !k.eq_ignore_ascii_case("authorization")));
    let r = t.get("localhost", port, "/v1/whoami?secret=q", sent).await;

    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert!(
        r.headers.contains("x-upstream"),
        "response came from the fake upstream"
    );
    let echo = json_body(&r);
    assert_eq!(
        echo["authorization_sha256"],
        sha256_hex(&format!("Bearer {TOKEN}")),
        "upstream got the injected credential"
    );
    assert_eq!(echo["saw_proxy_headers"], false);
    assert_eq!(echo["host"], format!("localhost:{port}"));
    assert_eq!(echo["path"], "/v1/whoami");
    // Nothing the sandbox received contains the token.
    assert!(!r.body.contains(TOKEN) && !r.headers.contains(TOKEN));

    // Audit trail: one structured line, and no secret or query string in it.
    let audit = wait_for(
        &w.logs(),
        |l| l.contains("\"path\":\"/v1/whoami\""),
        0,
        "audit line",
    )
    .await;
    let v: Value = serde_json::from_str(&audit).unwrap();
    let f = &v["fields"];
    assert_eq!(v["target"], "audit");
    assert_eq!(f["node"], w.sandbox_key.public().to_string());
    assert_eq!(f["host"], "localhost");
    assert_eq!(f["method"], "GET");
    assert_eq!(f["status"], 200);
    let all = w.logs().lock().unwrap().join("\n");
    assert!(!all.contains(TOKEN) && !all.contains("secret=q"));
}

#[tokio::test]
async fn keep_alive_tunnel_serves_several_requests() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    for i in 0..3 {
        let r = t.get("localhost", port, &format!("/n/{i}"), &[]).await;
        assert_eq!(r.status, StatusCode::OK);
        assert_eq!(json_body(&r)["path"], format!("/n/{i}"));
    }
}

#[tokio::test]
async fn host_header_must_match_the_tunnel() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    let r = t.get("evil.test", 443, "/", &[]).await;
    assert_eq!(r.status, StatusCode::MISDIRECTED_REQUEST);
    assert!(!r.body.contains("authorization"));
}

#[tokio::test]
async fn broker_refuses_hosts_outside_the_sandbox_policy() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    for (host, port) in [
        ("evil.test", 443u16),
        ("localhost", 443),
        ("localhost", w.upstream_port + 1),
    ] {
        let r = w
            .raw(
                w.sandbox_key.clone(),
                &Ctl::Connect {
                    host: host.into(),
                    port,
                },
            )
            .await
            .unwrap();
        assert!(
            matches!(r, CtlReply::Refused { .. }),
            "{host}:{port} -> {r:?}"
        );
    }
    wait_for(
        &w.logs(),
        |l| l.contains("\"event\":\"refused\"") && l.contains("evil.test"),
        0,
        "refusal of evil.test",
    )
    .await;
    // And what the sandbox is told it may use is exactly its own patterns.
    let r = w.raw(w.sandbox_key.clone(), &Ctl::Policy).await.unwrap();
    assert_eq!(
        r,
        CtlReply::Policy {
            hosts: vec![format!("localhost:{}", w.upstream_port)]
        }
    );
}

#[tokio::test]
async fn unknown_node_id_is_refused() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let stranger = SecretKey::generate();
    assert!(w.raw(stranger.clone(), &Ctl::Policy).await.is_err());
    assert!(w
        .raw(
            stranger,
            &Ctl::Connect {
                host: "localhost".into(),
                port: w.upstream_port
            }
        )
        .await
        .is_err());
    let line = wait_for(
        &w.logs(),
        |l| l.contains("unknown endpoint"),
        0,
        "audit line",
    )
    .await;
    assert!(line.contains("refused"), "{line}");
}

#[tokio::test]
async fn sighup_revokes_even_open_tunnels() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    assert_eq!(
        t.get("localhost", port, "/a", &[]).await.status,
        StatusCode::OK
    );

    w.write_policy(false);
    // Without SIGHUP nothing changes.
    assert_eq!(
        t.get("localhost", port, "/b", &[]).await.status,
        StatusCode::OK
    );
    w.reload().await;

    // The tunnel that was open is cut off at its next request...
    assert_eq!(
        t.get("localhost", port, "/c", &[]).await.status,
        StatusCode::FORBIDDEN
    );
    // ...and a new one cannot be made, even while the proxy's pattern list is stale.
    assert!(w.open_tunnel("localhost", port).await.is_err());

    // A broken edit keeps the old policy in force and says so.
    std::fs::write(w.store.dir().join("policy.toml"), "this is not toml [").unwrap();
    w.reload_expect_failure().await;
}

impl World {
    async fn reload_expect_failure(&self) {
        let b = self.broker.as_ref().unwrap();
        let pid = b.child.id().unwrap().to_string();
        assert!(std::process::Command::new("kill")
            .args(["-HUP", &pid])
            .status()
            .unwrap()
            .success());
        wait_for(&b.logs, |l| l.contains("reload failed"), 0, "reload failed").await;
    }
}

#[tokio::test]
async fn proxy_stops_routing_revoked_hosts_after_its_refresh() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let proxy = w.proxy.as_ref().unwrap();
    assert_eq!(proxy.patterns(), [format!("localhost:{}", w.upstream_port)]);
    w.write_policy(false);
    w.reload().await;
    for _ in 0..100 {
        if proxy.patterns().is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("proxy kept the revoked pattern");
}

#[tokio::test]
async fn broker_restart_reloads_everything_from_the_store() {
    let Some(bins) = bins() else { return };
    let mut w = World::ready(bins).await;
    let port = w.upstream_port;
    let before = w.broker_id;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    assert_eq!(
        t.get("localhost", port, "/", &[]).await.status,
        StatusCode::OK
    );

    w.crash_broker().await;
    w.start_broker().await;
    assert_eq!(w.broker_id, before, "same key file, same identity");

    // A fresh tunnel: the proxy notices its connection died and redials.
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    let r = t.get("localhost", port, "/", &[]).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert_eq!(
        json_body(&r)["authorization_sha256"],
        sha256_hex(&format!("Bearer {TOKEN}"))
    );
}

#[tokio::test]
async fn hosts_outside_policy_are_spliced_directly() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;

    let echo = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let echo_port = echo.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = echo.accept().await.unwrap();
            tokio::spawn(async move {
                let (mut r, mut wr) = s.split();
                let _ = tokio::io::copy(&mut r, &mut wr).await;
            });
        }
    });

    let audit_before = w
        .logs()
        .lock()
        .unwrap()
        .iter()
        .filter(|l| l.contains("\"audit\""))
        .count();
    let mut sock = TcpStream::connect(w.proxy_addr()).await.unwrap();
    sock.write_all(format!("CONNECT 127.0.0.1:{echo_port} HTTP/1.1\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut buf = vec![0u8; 39];
    sock.read_exact(&mut buf).await.unwrap();
    assert!(String::from_utf8_lossy(&buf).starts_with("HTTP/1.1 200"));
    sock.write_all(b"ping").await.unwrap();
    let mut pong = [0u8; 4];
    sock.read_exact(&mut pong).await.unwrap();
    assert_eq!(&pong, b"ping");

    // The broker never heard of it.
    let audit_after = w
        .logs()
        .lock()
        .unwrap()
        .iter()
        .filter(|l| l.contains("\"audit\""))
        .count();
    assert_eq!(audit_before, audit_after);

    // Non-CONNECT requests are refused outright.
    let mut s = TcpStream::connect(w.proxy_addr()).await.unwrap();
    s.write_all(b"GET http://example.test/ HTTP/1.1\r\n\r\n")
        .await
        .unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).await.unwrap();
    assert!(out.starts_with("HTTP/1.1 405"), "{out}");
}

#[tokio::test]
async fn bodies_are_framed_by_the_broker_not_the_client() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    let r = t
        .send(
            "POST",
            "localhost",
            port,
            "/up",
            &[],
            Bytes::from_static(b"hello"),
        )
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    let echo = json_body(&r);
    assert_eq!(echo["method"], "POST");
    assert_eq!(echo["body_len"], 5);
    assert_eq!(
        echo["authorization_sha256"],
        sha256_hex(&format!("Bearer {TOKEN}"))
    );

    // A client that sends both Content-Length and Transfer-Encoding cannot
    // make the upstream see anything but one consistent body.
    let mut raw = open_raw(&w, "localhost", port).await;
    let reply = raw
        .exchange(&format!(
            "POST /smuggle HTTP/1.1\r\nHost: localhost:{port}\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
        ))
        .await;
    if reply.starts_with("HTTP/1.1 200") {
        let body = reply.split("\r\n\r\n").nth(1).unwrap_or("");
        let v: Value = serde_json::from_str(body.trim()).unwrap_or(Value::Null);
        assert_eq!(v["body_len"], 3, "{reply}");
        assert_ne!(v["content_length"], "4", "{reply}");
    } else {
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
    }
}

/// A TLS tunnel to the broker for hand-written HTTP.
struct Raw {
    tls: tokio_rustls::client::TlsStream<TcpStream>,
}

async fn open_raw(w: &World, host: &str, port: u16) -> Raw {
    let mut sock = TcpStream::connect(w.proxy_addr()).await.unwrap();
    let authority = format_authority(host, port);
    sock.write_all(format!("CONNECT {authority} HTTP/1.1\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        let mut b = [0u8; 1];
        assert!(sock.read(&mut b).await.unwrap() > 0);
        head.push(b[0]);
    }
    assert!(String::from_utf8_lossy(&head).contains(" 200 "));
    let name = ServerName::try_from(host.to_string()).unwrap();
    let tls = client_tls(&w.broker_ca_pem())
        .connect(name, sock)
        .await
        .unwrap();
    Raw { tls }
}

impl Raw {
    /// Send `request` as is and read until the broker closes the tunnel.
    async fn exchange(&mut self, request: &str) -> String {
        self.tls.write_all(request.as_bytes()).await.unwrap();
        let mut out = Vec::new();
        let _ = tokio::time::timeout(Duration::from_secs(10), self.tls.read_to_end(&mut out)).await;
        String::from_utf8_lossy(&out).into_owned()
    }
}

#[tokio::test]
async fn hostile_requests_are_refused_without_reaching_the_upstream() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port = w.upstream_port;
    let status = |reply: &str| reply.lines().next().unwrap_or("").to_string();
    let host = format!("localhost:{port}");

    // Methods outside the list: 405, and the upstream never hears of them.
    for m in ["TRACE", "CONNECT", "PROPFIND", "LINK", "FOO"] {
        let mut raw = open_raw(&w, "localhost", port).await;
        let target = if m == "CONNECT" { host.as_str() } else { "/x" };
        let reply = raw
            .exchange(&format!(
                "{m} {target} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
            ))
            .await;
        assert!(status(&reply).contains(" 405 "), "{m}: {reply}");
        assert!(!reply.contains("x-upstream"), "{m}: {reply}");
    }
    // The allowed ones get through (OPTIONS too).
    for m in ["HEAD", "OPTIONS", "DELETE", "PUT", "PATCH"] {
        let mut t = w.open_tunnel("localhost", port).await.unwrap();
        let r = t.send(m, "localhost", port, "/ok", &[], Bytes::new()).await;
        assert_eq!(r.status, StatusCode::OK, "{m}: {}", r.body);
    }

    // Targets that are not origin-form: `OPTIONS *`, authority-form, absolute
    // form for another host, absolute form with the wrong scheme.
    for (line, want) in [
        ("OPTIONS * HTTP/1.1", " 400 "),
        ("GET * HTTP/1.1", " 400 "),
        ("GET evil.test:443 HTTP/1.1", " 400 "),
        ("GET https://evil.test/ HTTP/1.1", " 421 "),
        ("GET http://localhost/ HTTP/1.1", " 400 "),
    ] {
        let mut raw = open_raw(&w, "localhost", port).await;
        let reply = raw
            .exchange(&format!(
                "{line}\r\nHost: {host}\r\nConnection: close\r\n\r\n"
            ))
            .await;
        assert!(status(&reply).contains(want), "{line}: {reply}");
        assert!(!reply.contains("x-upstream"), "{line}: {reply}");
    }

    // Host headers that are not the tunnel's host, however they are dressed.
    for hosts in [
        format!("Host: localhost:{port}?.example.com"),
        format!("Host: localhost:{port}#x"),
        format!("Host: localhost:{port}@evil.test"),
        format!("Host: evil.test?.localhost:{port}"),
        format!("Host: {host}\r\nHost: evil.test"),
        format!("Host: {host}\r\nHost: {host}"),
        "Host: localhost:+".to_string() + &port.to_string(),
        "Host: ".to_string(),
    ] {
        let mut raw = open_raw(&w, "localhost", port).await;
        let reply = raw
            .exchange(&format!(
                "GET / HTTP/1.1\r\n{hosts}\r\nConnection: close\r\n\r\n"
            ))
            .await;
        assert!(
            status(&reply).contains(" 421 ") || status(&reply).contains(" 400 "),
            "{hosts}: {reply}"
        );
        assert!(!reply.contains("x-upstream"), "{hosts}: {reply}");
    }

    // After all that the broker is alive and serving.
    let mut t = w.open_tunnel("localhost", port).await.unwrap();
    assert_eq!(
        t.get("localhost", port, "/still-up", &[]).await.status,
        StatusCode::OK
    );
}

#[tokio::test]
async fn invalid_connect_hosts_are_refused_and_never_logged() {
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    w.write_rules(&[
        (format!("*.localhost:{}", w.upstream_port), "up".into()),
        (format!("localhost:{}", w.upstream_port), "up".into()),
    ]);
    w.reload().await;
    let port = w.upstream_port;
    for bad in [
        "evil.test?.localhost",
        "evil.test#.localhost",
        "a@b.localhost",
        "a b.localhost",
        "x\n{\"fake\":\"audit line\"}.localhost",
        "a..localhost",
        "",
        "-a.localhost",
        &"a".repeat(300),
    ] {
        let r = w
            .raw(
                w.sandbox_key.clone(),
                &Ctl::Connect {
                    host: bad.into(),
                    port,
                },
            )
            .await
            .unwrap();
        assert_eq!(
            r,
            CtlReply::Refused {
                reason: "bad host".into()
            },
            "{bad:?}"
        );
    }
    // A real subdomain is fine; the same name unnormalised is too.
    for ok in ["a.localhost", "A.Localhost."] {
        let r = w
            .raw(
                w.sandbox_key.clone(),
                &Ctl::Connect {
                    host: ok.into(),
                    port,
                },
            )
            .await
            .unwrap();
        assert_eq!(r, CtlReply::Connected, "{ok}");
    }
    let all = w.logs().lock().unwrap().join("\n");
    assert!(!all.contains("fake") && !all.contains("evil.test"), "{all}");
}

// ---------------------------------------------------------------- IPv6

#[tokio::test]
async fn upstream_on_ipv6_is_reached_by_name() {
    need_v6!();
    let name = need_v6_name!();
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    // Only ::1 listens, so tokenizer must dial IPv6 to reach it.
    let port6 = fake_upstream(&w.up_ca, "[::1]:0", name).await;
    w.seal_secret("up6", TOKEN, &format!("{name}:{port6}"));
    w.write_rules(&[(format!("{name}:{port6}"), "up6".into())]);
    w.reload().await;
    w.wait_patterns(&[format!("{name}:{port6}")]).await;

    let mut t = w.open_tunnel(name, port6).await.unwrap();
    let r = t.get(name, port6, "/v6", &[]).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    let echo = json_body(&r);
    assert_eq!(echo["host"], format!("{name}:{port6}"));
    assert_eq!(
        echo["authorization_sha256"],
        sha256_hex(&format!("Bearer {TOKEN}"))
    );
}

#[tokio::test]
async fn ipv6_literal_targets_are_admitted_and_tunneled() {
    need_v6!();
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let port6 = fake_upstream(&w.up_ca, "[::1]:0", "::1").await;
    // The same address spelled two ways: the pattern is compared as an address.
    w.seal_secret("up6", TOKEN, &format!("[::1]:{port6}"));
    w.write_rules(&[(format!("[0:0:0:0:0:0:0:1]:{port6}"), "up6".into())]);
    w.reload().await;
    w.wait_patterns(&[format!("[::1]:{port6}")]).await;

    // Raw control: every spelling of ::1 is admitted, other addresses are not.
    for host in ["::1", "[::1]", "0:0:0:0:0:0:0:1", "0::1"] {
        let r = w
            .raw(
                w.sandbox_key.clone(),
                &Ctl::Connect {
                    host: host.into(),
                    port: port6,
                },
            )
            .await
            .unwrap();
        assert_eq!(r, CtlReply::Connected, "{host}");
    }
    for host in ["::2", "127.0.0.1", "localhost"] {
        let r = w
            .raw(
                w.sandbox_key.clone(),
                &Ctl::Connect {
                    host: host.into(),
                    port: port6,
                },
            )
            .await
            .unwrap();
        assert!(matches!(r, CtlReply::Refused { .. }), "{host}: {r:?}");
    }

    // The whole path through the proxy's IPv6 listener: CONNECT [::1]:port,
    // TLS against a leaf with an IPv6 SAN, a Host header with brackets. The
    // broker admits it, tokenizer (patched to dial IPv6 literals) reaches the
    // upstream on [::1] and the upstream receives the injected credential.
    let mut t = open_tunnel(w.proxy_addr6(), "::1", port6, &w.broker_ca_pem())
        .await
        .unwrap();
    let r = t.get("::1", port6, "/lit", &[]).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    let echo = json_body(&r);
    assert_eq!(echo["host"], format!("[::1]:{port6}"));
    assert_eq!(
        echo["authorization_sha256"],
        sha256_hex(&format!("Bearer {TOKEN}"))
    );
    let line = wait_for(
        &w.logs(),
        |l| l.contains("\"path\":\"/lit\""),
        0,
        "audit line for the IPv6 request",
    )
    .await;
    let v: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["fields"]["host"], "::1");
    assert_eq!(v["fields"]["port"], port6);
    assert_eq!(v["fields"]["status"], r.status.as_u16());
}

#[tokio::test]
async fn the_whole_path_works_over_ipv6_only() {
    need_v6!();
    let Some(bins) = bins() else { return };
    let w = World::new_on(&bins, Net::V6Only).await;
    let mut w = w;
    w.start_broker().await;
    w.start_proxy().await;
    assert!(w.broker_addrs.iter().all(|a| a.is_ipv6()));
    w.wait_patterns(&[format!("localhost:{}", w.upstream_port)])
        .await;
    let port = w.upstream_port;
    let mut t = open_tunnel(w.proxy_addr6(), "localhost", port, &w.broker_ca_pem())
        .await
        .unwrap();
    let r = t.get("localhost", port, "/", &[]).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
}

#[tokio::test]
async fn direct_splice_reaches_ipv6_hosts() {
    need_v6!();
    let name = need_v6_name!();
    let Some(bins) = bins() else { return };
    let w = World::ready(bins).await;
    let echo = TcpListener::bind("[::1]:0").await.unwrap();
    let echo_port = echo.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = echo.accept().await.unwrap();
            tokio::spawn(async move {
                let (mut r, mut wr) = s.split();
                let _ = tokio::io::copy(&mut r, &mut wr).await;
            });
        }
    });
    // By IPv6 literal and by a name that resolves to ::1, over the proxy's
    // IPv4 and IPv6 listeners alike.
    for (proxy, target) in [
        (w.proxy_addr(), format!("[::1]:{echo_port}")),
        (w.proxy_addr6(), format!("[::1]:{echo_port}")),
        (w.proxy_addr(), format!("{name}:{echo_port}")),
        (w.proxy_addr6(), format!("{name}:{echo_port}")),
    ] {
        let mut sock = TcpStream::connect(proxy).await.unwrap();
        sock.write_all(format!("CONNECT {target} HTTP/1.1\r\n\r\n").as_bytes())
            .await
            .unwrap();
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut b = [0u8; 1];
            assert!(sock.read(&mut b).await.unwrap() > 0, "{target}");
            head.push(b[0]);
        }
        assert!(
            String::from_utf8_lossy(&head).starts_with("HTTP/1.1 200"),
            "{target}"
        );
        sock.write_all(b"ping").await.unwrap();
        let mut pong = [0u8; 4];
        sock.read_exact(&mut pong).await.unwrap();
        assert_eq!(&pong, b"ping", "{target}");
    }
    // Malformed targets are a 400 from the proxy, not a dial.
    for bad in ["::1:443", "[::1", "a.test?x:443", ":443", "a.test:0"] {
        let mut s = TcpStream::connect(w.proxy_addr()).await.unwrap();
        s.write_all(format!("CONNECT {bad} HTTP/1.1\r\n\r\n").as_bytes())
            .await
            .unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).await.unwrap();
        assert!(out.starts_with("HTTP/1.1 400"), "{bad}: {out}");
    }
}

#[tokio::test]
async fn seal_is_what_tokenizer_unseals() {
    let Some(bins) = bins() else { return };
    let open_key = yolo_broker_wire::hex(&SecretKey::generate().to_bytes());
    let sealkey = Command::new(&bins.stock)
        .arg("sealkey")
        .env("OPEN_KEY", &open_key)
        .output()
        .await
        .unwrap();
    let err = String::from_utf8(sealkey.stderr).unwrap();
    let seal_key = err
        .trim()
        .strip_prefix("export SEAL_KEY=")
        .unwrap()
        .to_string();

    // Through the CLI, bound to a store's password, written into the store.
    let tmp = tempfile::tempdir().unwrap();
    let store = FileStore::new(tmp.path());
    store.init("http://127.0.0.1:1").unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_yolo-broker"))
        .args(["seal", "--seal-key", &seal_key, "--id", "svc", "--store"])
        .arg(tmp.path())
        .args([
            "--json",
            r#"{"inject_processor":{"token":"abc"},"allowed_hosts":["api.test"]}"#,
        ])
        .output()
        .await
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let sealed = String::from_utf8(out.stdout).unwrap().trim().to_string();
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("secrets/svc"))
            .unwrap()
            .trim(),
        sealed
    );

    let un = Command::new(&bins.stock)
        .args(["unseal", "-token", &sealed])
        .env("OPEN_KEY", &open_key)
        .output()
        .await
        .unwrap();
    assert!(
        un.status.success(),
        "{}",
        String::from_utf8_lossy(&un.stderr)
    );
    let opened: Value = serde_json::from_slice(&un.stdout).unwrap();
    assert_eq!(opened["inject_processor"]["token"], "abc");
    assert_eq!(opened["allowed_hosts"], json!(["api.test"]));
    assert_eq!(
        opened["bearer_auth"]["digest"],
        seal::password_digest(&store.read_password().unwrap())
    );
    assert!(STANDARD.decode(&sealed).is_ok());
}
