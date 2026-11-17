//! A hostile sandbox against the real broker and real iroh, in this process.
//! No tokenizer is needed (a request that passes every check gets a 502 from
//! the dead tokenizer, which is itself the proof that it passed), so these
//! always run, `nix develop` or not.
//!
//! Timeouts are shortened to a few hundred milliseconds through `Limits`.

use std::net::{SocketAddr, UdpSocket};
use std::sync::Arc;
use std::time::{Duration, Instant};

use iroh::endpoint::{Connection, ConnectionError, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, SecretKey};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use yolo_broker::limits::Limits;
use yolo_broker::server::Broker;
use yolo_broker::store::FileStore;
use yolo_broker_wire::{
    bind_endpoint, read_frame, write_frame, EndpointOpts, Network, Request as Ctl,
    Response as CtlReply, ALPN,
};

fn has_v6() -> bool {
    UdpSocket::bind("[::1]:0").is_ok()
}

struct Env {
    _tmp: tempfile::TempDir,
    broker_ep: Endpoint,
    addrs: Vec<SocketAddr>,
    sandbox: SecretKey,
    ca_pem: String,
    /// Keep client endpoints alive for the test's length.
    clients: std::sync::Mutex<Vec<Endpoint>>,
}

/// A broker whose one sandbox may use `rules` (`host = secret "s"` entries),
/// with tokenizer at `tokenizer_url` (nothing listens there unless a test
/// says so).
async fn env(rules: &[&str], limits: Limits, tokenizer_url: &str) -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let store = FileStore::new(tmp.path().join("store"));
    store.init("http://127.0.0.1:1").unwrap();
    std::fs::write(store.dir().join("tokenizer-url"), tokenizer_url).unwrap();
    store.put_secret("s", "c2VhbGVk").unwrap();
    let sandbox = SecretKey::generate();
    let each: Vec<String> = rules
        .iter()
        .map(|h| format!("{{ host = \"{h}\", secret = \"s\" }}"))
        .collect();
    std::fs::write(
        store.dir().join("policy.toml"),
        format!(
            "[[sandbox]]\nid = \"{}\"\nrules = [{}]\n",
            sandbox.public(),
            each.join(", ")
        ),
    )
    .unwrap();
    let ca_pem = std::fs::read_to_string(store.dir().join("ca.pem")).unwrap();

    let broker = Broker::with_limits(store, limits).await.unwrap();
    let mut binds: Vec<SocketAddr> = vec!["127.0.0.1:0".parse().unwrap()];
    if has_v6() {
        binds.push("[::1]:0".parse().unwrap());
    }
    let ep = bind_endpoint(
        SecretKey::generate(),
        Network::Direct,
        vec![ALPN.to_vec()],
        broker.endpoint_opts(binds),
    )
    .await
    .unwrap();
    tokio::spawn(broker.clone().serve(ep.clone()));
    let addrs = ep
        .bound_sockets()
        .into_iter()
        .filter(|a| a.ip().is_loopback())
        .collect();
    Env {
        _tmp: tmp,
        broker_ep: ep,
        addrs,
        sandbox,
        ca_pem,
        clients: Default::default(),
    }
}

impl Env {
    /// A new connection to the broker as `key`, over `family` addresses only
    /// (None: all).
    async fn connect_as(&self, key: SecretKey, v6: Option<bool>) -> anyhow::Result<Connection> {
        let ep = bind_endpoint(
            key,
            Network::Direct,
            vec![],
            EndpointOpts::bind(["127.0.0.1:0".parse().unwrap()]),
        )
        .await?;
        let mut addr = EndpointAddr::new(self.broker_ep.id());
        for a in &self.addrs {
            if v6.is_none_or(|want| want == a.is_ipv6()) {
                addr = addr.with_ip_addr(*a);
            }
        }
        let conn = ep.connect(addr, ALPN).await?;
        self.clients.lock().unwrap().push(ep);
        Ok(conn)
    }

    async fn connect(&self) -> Connection {
        self.connect_as(self.sandbox.clone(), None).await.unwrap()
    }
}

async fn ctl(conn: &Connection, req: &Ctl) -> anyhow::Result<CtlReply> {
    let (mut send, mut recv) = conn.open_bi().await?;
    write_frame(&mut send, req).await?;
    tokio::time::timeout(Duration::from_secs(5), read_frame(&mut recv)).await?
}

fn connect_req(host: &str, port: u16) -> Ctl {
    Ctl::Connect {
        host: host.into(),
        port,
    }
}

type Io = tokio::io::Join<RecvStream, SendStream>;
type Tls = tokio_rustls::client::TlsStream<Io>;

fn client_tls(ca_pem: &str) -> tokio_rustls::TlsConnector {
    let mut roots = rustls::RootCertStore::empty();
    for c in CertificateDer::pem_slice_iter(ca_pem.as_bytes()) {
        roots.add(c.unwrap()).unwrap();
    }
    let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    tokio_rustls::TlsConnector::from(Arc::new(cfg))
}

/// Open a tunnel to `host:port`, up to a finished TLS handshake.
async fn tunnel(env: &Env, conn: &Connection, host: &str, port: u16) -> Tls {
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_frame(&mut send, &connect_req(host, port))
        .await
        .unwrap();
    let reply: CtlReply = read_frame(&mut recv).await.unwrap();
    assert_eq!(reply, CtlReply::Connected, "{host}:{port}");
    let name = ServerName::try_from(host.to_string()).unwrap();
    client_tls(&env.ca_pem)
        .connect(name, tokio::io::join(recv, send))
        .await
        .unwrap()
}

/// Send `request` as is and read until the broker ends the tunnel (or 8 s).
async fn http(tls: &mut Tls, request: &str) -> String {
    tls.write_all(request.as_bytes()).await.unwrap();
    let mut out = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(8), tls.read_to_end(&mut out)).await;
    String::from_utf8_lossy(&out).into_owned()
}

fn status(reply: &str) -> &str {
    reply.lines().next().unwrap_or("")
}

fn quick() -> Limits {
    Limits {
        control_read: Duration::from_millis(300),
        tls_accept: Duration::from_millis(300),
        header_read: Duration::from_millis(300),
        idle: Duration::from_millis(400),
        tokenizer_connect: Duration::from_millis(300),
        tokenizer_request: Duration::from_millis(400),
        ..Limits::default()
    }
}

/// Nothing listens here.
const DEAD_TOKENIZER: &str = "http://127.0.0.1:1";

// ------------------------------------------------------------------ requests

#[tokio::test]
async fn bad_methods_targets_and_hosts_never_get_past_the_broker() {
    let env = env(&["a.test"], Limits::default(), DEAD_TOKENIZER).await;
    let conn = env.connect().await;
    let ok_host = "Host: a.test\r\nConnection: close\r\n\r\n";

    for m in ["TRACE", "CONNECT", "PROPFIND", "FOO"] {
        let mut t = tunnel(&env, &conn, "a.test", 443).await;
        let r = http(&mut t, &format!("{m} /x HTTP/1.1\r\n{ok_host}")).await;
        assert!(status(&r).contains(" 405 "), "{m}: {r}");
    }
    // `OPTIONS *`, authority-form, absolute-form for another host or scheme
    for (line, want) in [
        ("OPTIONS * HTTP/1.1", " 400 "),
        ("GET * HTTP/1.1", " 400 "),
        ("GET a.test:443 HTTP/1.1", " 400 "),
        ("GET https://evil.test/ HTTP/1.1", " 421 "),
        ("GET http://a.test/ HTTP/1.1", " 400 "),
    ] {
        let mut t = tunnel(&env, &conn, "a.test", 443).await;
        let r = http(&mut t, &format!("{line}\r\n{ok_host}")).await;
        assert!(status(&r).contains(want), "{line}: {r}");
    }
    // Host headers that are not the tunnel's host
    for hosts in [
        "Host: a.test?.example.com",
        "Host: a.test#x",
        "Host: a.test@evil.test",
        "Host: evil.test?.a.test",
        "Host: a.test\r\nHost: evil.test",
        "Host: a.test\r\nHost: a.test",
        "Host: a.test:+443",
        "Host: ",
        "Host: A.TEST:8443",
    ] {
        let mut t = tunnel(&env, &conn, "a.test", 443).await;
        let r = http(
            &mut t,
            &format!("GET / HTTP/1.1\r\n{hosts}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert!(
            status(&r).contains(" 421 ") || status(&r).contains(" 400 "),
            "{hosts}: {r}"
        );
    }
    // Allowed requests pass every check and reach the (dead) tokenizer: 502.
    for (m, host) in [
        ("GET", "a.test"),
        ("GET", "A.TEST"),
        ("GET", "a.test:443"),
        ("OPTIONS", "a.test"),
        ("DELETE", "a.test"),
    ] {
        let mut t = tunnel(&env, &conn, "a.test", 443).await;
        let r = http(
            &mut t,
            &format!("{m} /p?q=1 HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert!(status(&r).contains(" 502 "), "{m} {host}: {r}");
    }
    let mut t = tunnel(&env, &conn, "a.test", 443).await;
    let r = http(
        &mut t,
        "GET https://a.test/abs HTTP/1.1\r\nHost: a.test\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(
        status(&r).contains(" 502 "),
        "absolute-form, same host: {r}"
    );
}

#[tokio::test]
async fn control_frames_with_bad_hosts_are_refused() {
    let env = env(&["*.a.test", "a.test"], Limits::default(), DEAD_TOKENIZER).await;
    let conn = env.connect().await;
    for bad in [
        "evil.test?.a.test",
        "evil.test#.a.test",
        "evil.test@x.a.test",
        "x y.a.test",
        "x\n.a.test",
        "x..a.test",
        "",
        "-x.a.test",
        &"x".repeat(300),
    ] {
        let r = ctl(&conn, &connect_req(bad, 443)).await.unwrap();
        assert_eq!(
            r,
            CtlReply::Refused {
                reason: "bad host".into()
            },
            "{bad:?}"
        );
    }
    let r = ctl(&conn, &connect_req("x.a.test", 0)).await.unwrap();
    assert_eq!(
        r,
        CtlReply::Refused {
            reason: "bad port".into()
        }
    );
    for ok in ["x.a.test", "X.A.TEST.", "a.test"] {
        let r = ctl(&conn, &connect_req(ok, 443)).await.unwrap();
        assert_eq!(r, CtlReply::Connected, "{ok}");
    }
}

// --------------------------------------------------------------------- IPv6

#[tokio::test]
async fn ipv6_tunnel_over_ipv6_iroh() {
    if !has_v6() {
        eprintln!("SKIPPED: this host has no ::1");
        return;
    }
    // The pattern is written one way, the sandbox asks another.
    let env = env(
        &["[0:0:0:0:0:0:0:1]:8443", "[::1]"],
        Limits::default(),
        DEAD_TOKENIZER,
    )
    .await;
    let conn = env
        .connect_as(env.sandbox.clone(), Some(true))
        .await
        .unwrap();
    assert!(conn.remote_id() == env.broker_ep.id());

    let r = ctl(&conn, &Ctl::Policy).await.unwrap();
    assert_eq!(
        r,
        CtlReply::Policy {
            hosts: vec!["[::1]:8443".into(), "[::1]".into()]
        }
    );
    for host in ["::1", "[::1]", "0:0:0:0:0:0:0:1"] {
        assert_eq!(
            ctl(&conn, &connect_req(host, 8443)).await.unwrap(),
            CtlReply::Connected,
            "{host}"
        );
    }
    assert!(matches!(
        ctl(&conn, &connect_req("::2", 8443)).await.unwrap(),
        CtlReply::Refused { .. }
    ));

    // TLS to a leaf with an IPv6 SAN, a bracketed Host header: every check
    // passes, and the request is built for tokenizer (which is dead: 502).
    let mut t = tunnel(&env, &conn, "::1", 8443).await;
    let r = http(
        &mut t,
        "GET /v6 HTTP/1.1\r\nHost: [::1]:8443\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(status(&r).contains(" 502 "), "{r}");
    let mut t = tunnel(&env, &conn, "::1", 443).await;
    let r = http(
        &mut t,
        "GET /v6 HTTP/1.1\r\nHost: [::1]\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(status(&r).contains(" 502 "), "{r}");
    // Unbracketed, or the wrong address, is not the tunnel's host.
    for host in ["::1", "[::2]:8443", "127.0.0.1:8443", "[::1]x"] {
        let mut t = tunnel(&env, &conn, "::1", 8443).await;
        let r = http(
            &mut t,
            &format!("GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert!(
            status(&r).contains(" 421 ") || status(&r).contains(" 400 "),
            "{host}: {r}"
        );
    }
}

#[tokio::test]
async fn tokenizer_at_an_ipv6_address_is_dialed() {
    if !has_v6() {
        eprintln!("SKIPPED: this host has no ::1");
        return;
    }
    // A stand-in tokenizer on [::1]: answers any request with a 200.
    let l = TcpListener::bind("[::1]:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = l.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let _ = s.read(&mut buf).await;
                let _ = s
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                    )
                    .await;
            });
        }
    });
    let env = env(
        &["a.test"],
        Limits::default(),
        &format!("http://[::1]:{port}"),
    )
    .await;
    let conn = env.connect().await;
    let mut t = tunnel(&env, &conn, "a.test", 443).await;
    let r = http(
        &mut t,
        "GET / HTTP/1.1\r\nHost: a.test\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(status(&r).contains(" 200 "), "{r}");
    assert!(r.ends_with("ok"), "{r}");
}

// ----------------------------------------------------------------- timeouts

#[tokio::test]
async fn a_control_frame_that_never_finishes_is_cut() {
    let env = env(&["a.test"], quick(), DEAD_TOKENIZER).await;
    let conn = env.connect().await;
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    send.write_all(&[0u8]).await.unwrap(); // one byte of a four-byte length
    let t = Instant::now();
    let r = tokio::time::timeout(Duration::from_secs(5), recv.read_to_end(1024))
        .await
        .expect("the broker gave up on the stream");
    assert!(
        t.elapsed() >= Duration::from_millis(250),
        "{:?}",
        t.elapsed()
    );
    assert!(t.elapsed() < Duration::from_secs(3));
    assert!(r.is_err() || r.unwrap().is_empty());
}

#[tokio::test]
async fn a_tls_handshake_that_never_starts_is_cut() {
    let env = env(&["a.test"], quick(), DEAD_TOKENIZER).await;
    let conn = env.connect().await;
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_frame(&mut send, &connect_req("a.test", 443))
        .await
        .unwrap();
    assert_eq!(
        read_frame::<_, CtlReply>(&mut recv).await.unwrap(),
        CtlReply::Connected
    );
    let t = Instant::now();
    let mut rest = Vec::new();
    let r = tokio::time::timeout(Duration::from_secs(5), recv.read_to_end(1024))
        .await
        .expect("the broker gave up on the handshake");
    let _ = r.map(|b| rest = b);
    assert!(t.elapsed() < Duration::from_secs(3), "{:?}", t.elapsed());
}

#[tokio::test]
async fn slow_headers_and_idle_tunnels_are_cut() {
    // Header read timeout: a request line that never ends.
    let env1 = env(
        &["a.test"],
        Limits {
            idle: Duration::from_secs(60),
            ..quick()
        },
        DEAD_TOKENIZER,
    )
    .await;
    let conn = env1.connect().await;
    let mut t = tunnel(&env1, &conn, "a.test", 443).await;
    t.write_all(b"GET / HTTP/1.1\r\nHost: a.te").await.unwrap();
    let started = Instant::now();
    let mut sink = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(5), t.read_to_end(&mut sink))
        .await
        .expect("header read timeout");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );

    // Idle timeout: header timeout out of the way, the tunnel just sits there.
    let env2 = env(
        &["a.test"],
        Limits {
            header_read: Duration::from_secs(60),
            ..quick()
        },
        DEAD_TOKENIZER,
    )
    .await;
    let conn = env2.connect().await;
    let mut t = tunnel(&env2, &conn, "a.test", 443).await;
    t.write_all(b"GET / HTTP/1.1\r\nHost: a.te").await.unwrap();
    let started = Instant::now();
    let mut sink = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(5), t.read_to_end(&mut sink))
        .await
        .expect("idle timeout");
    assert!(
        started.elapsed() >= Duration::from_millis(350),
        "{:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );
}

#[tokio::test]
async fn a_hung_or_dead_tokenizer_is_a_502_not_a_hang() {
    // Dead: connection refused.
    let env1 = env(&["a.test"], quick(), DEAD_TOKENIZER).await;
    let conn = env1.connect().await;
    let mut t = tunnel(&env1, &conn, "a.test", 443).await;
    let r = http(
        &mut t,
        "GET / HTTP/1.1\r\nHost: a.test\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(status(&r).contains(" 502 "), "{r}");

    // Hung: accepts and never answers.
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut held = Vec::new();
        loop {
            held.push(l.accept().await.unwrap());
        }
    });
    // (The idle timeout must outlast the tokenizer timeout, as it does by default.)
    let limits = Limits {
        idle: Duration::from_secs(10),
        ..quick()
    };
    let env2 = env(&["a.test"], limits, &format!("http://127.0.0.1:{port}")).await;
    let conn = env2.connect().await;
    let mut t = tunnel(&env2, &conn, "a.test", 443).await;
    let started = Instant::now();
    let r = http(
        &mut t,
        "GET / HTTP/1.1\r\nHost: a.test\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(status(&r).contains(" 502 "), "{r}");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );
}

// ------------------------------------------------------------------- limits

/// A stream that has started but not finished its control frame holds a slot.
async fn stalled(conn: &Connection) -> (SendStream, RecvStream) {
    let (mut send, recv) = conn.open_bi().await.unwrap();
    send.write_all(&[0u8]).await.unwrap();
    (send, recv)
}

#[tokio::test]
async fn per_sandbox_stream_limit() {
    let limits = Limits {
        control_read: Duration::from_secs(30),
        max_streams_per_node: 2,
        ..Limits::default()
    };
    let env = env(&["a.test"], limits, DEAD_TOKENIZER).await;
    let a = env.connect().await;
    let _held = [stalled(&a).await, stalled(&a).await];
    // Give the broker a moment to take both streams.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // A second connection of the same sandbox has no slot left.
    let b = env.connect().await;
    assert_eq!(
        ctl(&b, &Ctl::Policy).await.unwrap(),
        CtlReply::Refused {
            reason: "too many open streams".into()
        }
    );
    // The QUIC limit is the same number: a third stream on one connection
    // cannot even be opened until one finishes.
    let third = tokio::time::timeout(Duration::from_millis(500), a.open_bi()).await;
    assert!(third.is_err(), "a third bi-stream was opened");

    // Releasing the slots lets the sandbox back in.
    a.close(0u32.into(), b"done");
    let mut ok = false;
    for _ in 0..40 {
        if matches!(ctl(&b, &Ctl::Policy).await, Ok(CtlReply::Policy { .. })) {
            ok = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(ok, "slots were never released");
}

#[tokio::test]
async fn global_stream_limit() {
    let limits = Limits {
        control_read: Duration::from_secs(30),
        max_streams: 1,
        ..Limits::default()
    };
    let env = env(&["a.test"], limits, DEAD_TOKENIZER).await;
    let a = env.connect().await;
    let _held = stalled(&a).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let b = env.connect().await;
    assert_eq!(
        ctl(&b, &Ctl::Policy).await.unwrap(),
        CtlReply::Refused {
            reason: "too many open streams".into()
        }
    );
}

#[tokio::test]
async fn unknown_endpoints_are_dropped_at_the_handshake() {
    let env = env(&["a.test"], Limits::default(), DEAD_TOKENIZER).await;
    let stranger = env
        .connect_as(SecretKey::generate(), None)
        .await
        .expect("the handshake itself completes");
    let closed = tokio::time::timeout(Duration::from_secs(3), stranger.closed())
        .await
        .expect("the broker closed the connection");
    match closed {
        ConnectionError::ApplicationClosed(c) => {
            assert_eq!(u64::from(c.error_code), 403);
            assert_eq!(&c.reason[..], b"unknown endpoint");
        }
        other => panic!("{other:?}"),
    }
    assert!(ctl(&stranger, &Ctl::Policy).await.is_err());
}
