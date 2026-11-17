//! What the broker and the sandbox proxy agree on: the ALPN, the control
//! messages that open each iroh bi-stream, host patterns, and secret key files.
//!
//! Each bi-stream the proxy opens starts with one framed [`Request`] and gets
//! one framed [`Response`]. After a `Connect` that was answered
//! [`Response::Connected`], the stream carries the sandbox's raw TLS bytes.

pub mod cli;
pub mod host;

use std::fmt;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub use iroh;

/// ALPN of the broker's iroh endpoint.
pub const ALPN: &[u8] = b"yolo-broker/0";

pub use host::{
    canonical_host, format_authority, split_authority, Host, DEFAULT_PORT, MAX_HOST_LEN,
};

const MAX_FRAME: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// Which host patterns may this sandbox send through the broker?
    Policy,
    /// Tunnel TLS for `host:port` through the broker.
    Connect { host: String, port: u16 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Response {
    Policy { hosts: Vec<String> },
    Connected,
    Refused { reason: String },
}

// ---------------------------------------------------------------- patterns

/// A host pattern from a policy: `api.example.com`, `*.example.com`, an IP
/// literal (`192.0.2.1`, `[::1]`), or any of them with `:port`. A pattern
/// without a port stands for port 443. A wildcard is for DNS names only and
/// matches one or more labels under the suffix, never the bare suffix. IP
/// literals compare as addresses, so `[::1]` and `[0:0:0:0:0:0:0:1]` are one
/// pattern. Hosts are validated by [`host::Host`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HostPattern {
    suffix_wildcard: bool,
    host: Host,
    port: u16,
}

impl HostPattern {
    pub fn parse(s: &str) -> Result<Self> {
        let s = s.trim();
        let (wild, rest) = match s.strip_prefix("*.") {
            Some(rest) => (true, rest),
            None => (false, s),
        };
        let (h, port) = host::split_host_port(rest)
            .and_then(|(h, p)| Ok((Host::parse(h)?, p.unwrap_or(DEFAULT_PORT))))
            .with_context(|| format!("bad host pattern {s:?}"))?;
        if wild && !h.is_dns() {
            bail!("bad host pattern {s:?}: wildcards are for DNS names only");
        }
        Ok(Self {
            suffix_wildcard: wild,
            host: h,
            port,
        })
    }

    /// Does `host:port` fall under this pattern? A host that is not valid (see
    /// [`host::Host`]) matches nothing.
    pub fn matches(&self, host: &str, port: u16) -> bool {
        if port != self.port {
            return false;
        }
        let Ok(host) = Host::parse(host) else {
            return false;
        };
        match (&self.host, &host) {
            (Host::Dns(suffix), Host::Dns(name)) if self.suffix_wildcard => {
                name.len() > suffix.len() + 1
                    && name.ends_with(suffix.as_str())
                    && name.as_bytes()[name.len() - suffix.len() - 1] == b'.'
            }
            _ if self.suffix_wildcard => false,
            (mine, theirs) => mine == theirs,
        }
    }

    /// Higher is more specific: an exact host beats any wildcard, a longer
    /// wildcard suffix beats a shorter one.
    pub fn specificity(&self) -> usize {
        if self.suffix_wildcard {
            self.host.to_string().len()
        } else {
            usize::MAX
        }
    }
}

impl fmt::Display for HostPattern {
    /// The canonical form, which parses back to the same pattern.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.suffix_wildcard {
            f.write_str("*.")?;
        }
        f.write_str(&self.host.bracketed())?;
        if self.port != DEFAULT_PORT {
            write!(f, ":{}", self.port)?;
        }
        Ok(())
    }
}

/// Hex of a 32-byte key, the form iroh prints for endpoint ids.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(s: &str) -> Result<Vec<u8>> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        bail!("bad hex");
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).context("bad hex"))
        .collect()
}

// ----------------------------------------------------------------- framing

pub async fn write_frame<W: AsyncWrite + Unpin, T: Serialize>(w: &mut W, msg: &T) -> Result<()> {
    let body = serde_json::to_vec(msg)?;
    if body.len() > MAX_FRAME {
        bail!("frame too large");
    }
    w.write_all(&(body.len() as u32).to_be_bytes()).await?;
    w.write_all(&body).await?;
    w.flush().await?;
    Ok(())
}

pub async fn read_frame<R: AsyncRead + Unpin, T: for<'de> Deserialize<'de>>(
    r: &mut R,
) -> Result<T> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        bail!("frame too large");
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    Ok(serde_json::from_slice(&body)?)
}

// -------------------------------------------------------------------- keys

/// An iroh secret key is 32 bytes, stored as 64 hex characters.
pub fn parse_secret_key(s: &str) -> Result<iroh::SecretKey> {
    let bytes: [u8; 32] = unhex(s)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("secret key must be 32 bytes"))?;
    Ok(iroh::SecretKey::from_bytes(&bytes))
}

/// Read the key at `path`, or create it (mode 0600) when the file is missing.
/// An existing key file readable by group or other is refused.
pub fn load_or_create_secret_key(path: &Path) -> Result<iroh::SecretKey> {
    match read_private(path) {
        Ok(s) => parse_secret_key(&s).with_context(|| format!("{}", path.display())),
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            let key = iroh::SecretKey::generate();
            write_private(path, format!("{}\n", hex(&key.to_bytes())).as_bytes())?;
            Ok(key)
        }
        Err(e) => Err(e),
    }
}

/// Resolve a key from the environment variable `env` (hex), else from the file.
pub fn resolve_secret_key(env: &str, file: &Path) -> Result<iroh::SecretKey> {
    match std::env::var(env) {
        Ok(v) if !v.trim().is_empty() => parse_secret_key(&v).with_context(|| env.to_string()),
        _ => load_or_create_secret_key(file),
    }
}

/// Create `dir` and any missing parents with mode 0700.
pub fn create_private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if dir.as_os_str().is_empty() {
        return Ok(());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("creating {}", dir.display()))
}

/// Refuse a directory that group or other can enter, list or change.
pub fn check_private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(dir).with_context(|| format!("{}", dir.display()))?;
    let mode = meta.permissions().mode() & 0o777;
    if !meta.is_dir() {
        bail!("{} is not a directory", dir.display());
    }
    if mode & 0o077 != 0 {
        bail!(
            "{} has mode {mode:o}; it must not be accessible to group or other (chmod 700)",
            dir.display()
        );
    }
    Ok(())
}

/// Write a file (mode 0600), creating missing parent directories with mode
/// 0700. Symlinks are not followed, and the mode is set on the open file, so
/// an existing file with looser bits is tightened.
pub fn write_private(path: &Path, data: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if let Some(dir) = path.parent() {
        create_private_dir(dir)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .with_context(|| format!("{}", path.display()))?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    f.write_all(data)?;
    Ok(())
}

/// Read a file that holds a secret. It must be a regular file (symlinks are
/// not followed) that group and other cannot access; otherwise this fails
/// without returning the contents. A missing file is an `io::Error` of kind
/// `NotFound` in the error chain's root.
pub fn read_private(path: &Path) -> Result<String> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let meta = f.metadata()?;
    if !meta.is_file() {
        bail!("{} is not a regular file", path.display());
    }
    if meta.mode() & 0o077 != 0 {
        bail!(
            "{} has mode {:o}; a secret file must not be accessible to group or other (chmod 600)",
            path.display(),
            meta.mode() & 0o777
        );
    }
    let mut s = String::new();
    f.read_to_string(&mut s)
        .with_context(|| format!("{}", path.display()))?;
    Ok(s)
}

// --------------------------------------------------------------- endpoints

/// How a process reaches other iroh endpoints.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    /// n0's relays and DNS address lookup: dial by endpoint id alone.
    Default,
    /// No relays, no lookup: dial by explicit socket addresses only.
    Direct,
}

/// Decides, right after the handshake, whether a remote endpoint may stay
/// connected at all.
pub type Admit = Arc<dyn Fn(&iroh::EndpointId) -> bool + Send + Sync>;

/// Everything optional about an iroh endpoint.
#[derive(Default, Clone)]
pub struct EndpointOpts {
    /// Local socket addresses, at most one per address family. iroh always
    /// binds `0.0.0.0:0` and `[::]:0` unless told otherwise, so a family
    /// without an entry here stays on that wildcard (the IPv6 one may fail
    /// quietly on a host without IPv6). An entry replaces the wildcard of its
    /// family only. Empty: both wildcards.
    pub bind: Vec<SocketAddr>,
    /// Cap on concurrently open bi-streams per connection (the peer cannot
    /// open more). None: iroh's default.
    pub max_bidi_streams: Option<u32>,
    /// Drop connections from endpoints this refuses, as early as iroh allows
    /// (after the TLS handshake, which is when the endpoint id is known).
    pub admit: Option<Admit>,
}

impl EndpointOpts {
    pub fn bind(addrs: impl IntoIterator<Item = SocketAddr>) -> Self {
        Self {
            bind: addrs.into_iter().collect(),
            ..Self::default()
        }
    }
}

struct AdmitHook(Admit);

impl fmt::Debug for AdmitHook {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AdmitHook")
    }
}

impl iroh::endpoint::EndpointHooks for AdmitHook {
    async fn after_handshake<'a>(
        &'a self,
        conn: &'a iroh::endpoint::Connection,
    ) -> iroh::endpoint::AfterHandshakeOutcome {
        if (self.0)(&conn.remote_id()) {
            iroh::endpoint::AfterHandshakeOutcome::Accept
        } else {
            iroh::endpoint::AfterHandshakeOutcome::Reject {
                error_code: iroh::endpoint::VarInt::from_u32(403),
                reason: b"unknown endpoint".to_vec(),
            }
        }
    }
}

pub async fn bind_endpoint(
    secret: iroh::SecretKey,
    network: Network,
    alpns: Vec<Vec<u8>>,
    opts: EndpointOpts,
) -> Result<iroh::Endpoint> {
    use iroh::endpoint::{presets, QuicTransportConfig, VarInt};
    let mut b = match network {
        Network::Default => iroh::Endpoint::builder(presets::N0),
        Network::Direct => {
            iroh::Endpoint::builder(presets::Minimal).relay_mode(iroh::RelayMode::Disabled)
        }
    }
    .secret_key(secret)
    .alpns(alpns);
    let (mut v4, mut v6) = (false, false);
    for addr in &opts.bind {
        let seen = if addr.is_ipv4() { &mut v4 } else { &mut v6 };
        if std::mem::replace(seen, true) {
            bail!("--bind {addr}: at most one bind address per IP family (one IPv4, one IPv6)");
        }
        b = b
            .bind_addr(*addr)
            .with_context(|| format!("--bind {addr}"))?;
    }
    if let Some(n) = opts.max_bidi_streams {
        b = b.transport_config(
            QuicTransportConfig::builder()
                .max_concurrent_bidi_streams(VarInt::from_u32(n))
                .max_concurrent_uni_streams(VarInt::from_u32(0))
                .build(),
        );
    }
    if let Some(admit) = opts.admit {
        b = b.hooks(AdmitHook(admit));
    }
    Ok(b.bind().await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> HostPattern {
        HostPattern::parse(s).unwrap()
    }

    #[test]
    fn exact_matches_default_port_only() {
        assert!(p("api.example.com").matches("API.example.com", 443));
        assert!(p("api.example.com").matches("api.example.com.", 443));
        assert!(!p("api.example.com").matches("api.example.com", 8443));
        assert!(!p("api.example.com").matches("x.api.example.com", 443));
        assert!(!p("api.example.com").matches("example.com", 443));
    }

    #[test]
    fn explicit_port() {
        assert!(p("localhost:8443").matches("localhost", 8443));
        assert!(!p("localhost:8443").matches("localhost", 443));
    }

    #[test]
    fn wildcard_needs_a_label() {
        let w = p("*.example.com");
        assert!(w.matches("a.example.com", 443));
        assert!(w.matches("a.b.example.com", 443));
        assert!(!w.matches("example.com", 443));
        assert!(!w.matches("notexample.com", 443));
        assert!(!w.matches("xexample.com", 443));
        assert!(!w.matches(".example.com", 443));
    }

    #[test]
    fn specificity_orders_exact_first() {
        assert!(p("a.example.com").specificity() > p("*.example.com").specificity());
        assert!(p("*.b.example.com").specificity() > p("*.example.com").specificity());
    }

    #[test]
    fn rejects_bad_patterns() {
        for bad in [
            "",
            "*",
            "*.",
            "a..b",
            "a b",
            "x:0",
            "x:nope",
            ".a.com",
            "a/b",
            "*.[::1]",
            "*.1.2.3.4",
            "[::1",
            "::1:443",
            "a.com?",
            "*.*.a.com",
            "a.*.com",
            "a_b.com",
        ] {
            assert!(HostPattern::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn wildcard_does_not_match_authority_tricks() {
        // `evil.com?.example.com` ends with `.example.com`, and as a URI
        // authority reads as `evil.com`. It is not a host at all.
        let w = p("*.example.com");
        for h in [
            "evil.com?.example.com",
            "evil.com#.example.com",
            "evil.com@x.example.com",
            "evil.com/.example.com",
            "a b.example.com",
            "a..example.com",
            "..example.com",
            "x\n.example.com",
            "",
        ] {
            assert!(!w.matches(h, 443), "{h:?}");
        }
        assert!(!p("example.com").matches("example.com?", 443));
        assert!(w.matches("A.Example.COM.", 443));
    }

    #[test]
    fn ipv6_patterns() {
        let v6 = p("[::1]:8443");
        assert!(v6.matches("::1", 8443));
        assert!(v6.matches("[::1]", 8443));
        assert!(v6.matches("0:0:0:0:0:0:0:1", 8443));
        assert!(!v6.matches("::1", 443));
        assert!(!v6.matches("::2", 8443));
        assert!(!v6.matches("127.0.0.1", 8443));
        assert_eq!(p("[0:0:0:0:0:0:0:1]:8443"), v6);
        assert_eq!(v6.to_string(), "[::1]:8443");
        assert_eq!(p("[2001:DB8::1]").to_string(), "[2001:db8::1]");
        assert_eq!(p(&p("[::1]").to_string()), p("[::1]"));
        assert!(p("[::1]").matches("::1", 443));
        // a bare IPv6 address is ambiguous with host:port, and wildcards are DNS-only
        assert!(HostPattern::parse("::1").is_err());
        assert!(HostPattern::parse("::1:8443").is_err());
        assert!(HostPattern::parse("*.[::1]").is_err());
        assert!(p("192.0.2.1").matches("192.0.2.1", 443));
        assert!(!p("192.0.2.1").matches("192.0.2.10", 443));
        // a wildcard over a name never matches an address
        assert!(!p("*.example.com").matches("::1", 443));
    }

    #[test]
    fn display_roundtrips() {
        for s in ["api.example.com", "*.example.com", "localhost:8443"] {
            assert_eq!(p(s).to_string(), s);
            assert_eq!(p(&p(s).to_string()), p(s));
        }
        assert_eq!(p("a.com:443").to_string(), "a.com");
    }

    #[tokio::test]
    async fn frames_roundtrip() {
        let (mut a, mut b) = tokio::io::duplex(1024);
        let req = Request::Connect {
            host: "a.com".into(),
            port: 443,
        };
        write_frame(&mut a, &req).await.unwrap();
        let got: Request = read_frame(&mut b).await.unwrap();
        assert_eq!(got, req);
    }

    #[test]
    fn private_files_are_0600_and_loose_ones_are_refused() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let tmp = tempfile::tempdir().unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;

        let key = tmp.path().join("new/dir/k");
        let made = load_or_create_secret_key(&key).unwrap();
        assert_eq!(mode(&key), 0o600);
        assert_eq!(mode(key.parent().unwrap()), 0o700);
        assert_eq!(
            load_or_create_secret_key(&key).unwrap().public(),
            made.public()
        );

        // group/other bits: refused on load, never read
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o640)).unwrap();
        let err = load_or_create_secret_key(&key).unwrap_err().to_string();
        assert!(err.contains("chmod 600"), "{err}");

        // write_private tightens a file that already exists with looser bits
        write_private(&key, b"x").unwrap();
        assert_eq!(mode(&key), 0o600);

        // symlinks are not followed, for write or read
        let target = tmp.path().join("target");
        std::fs::write(&target, "keep").unwrap();
        let link = tmp.path().join("link");
        symlink(&target, &link).unwrap();
        assert!(write_private(&link, b"pwned").is_err());
        assert!(read_private(&link).is_err());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "keep");

        // directories
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(check_private_dir(tmp.path()).is_err());
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(check_private_dir(tmp.path()).is_ok());
    }

    #[tokio::test]
    async fn bind_takes_one_address_per_family() {
        let secret = iroh::SecretKey::generate();
        let two_v4 = EndpointOpts::bind([
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.2:0".parse().unwrap(),
        ]);
        assert!(
            bind_endpoint(secret.clone(), Network::Direct, vec![], two_v4)
                .await
                .is_err()
        );
        let v4 = EndpointOpts::bind(["127.0.0.1:0".parse().unwrap()]);
        let ep = bind_endpoint(secret, Network::Direct, vec![], v4)
            .await
            .unwrap();
        ep.close().await;
    }

    #[test]
    fn key_hex_roundtrip() {
        let k = iroh::SecretKey::generate();
        let back = parse_secret_key(&hex(&k.to_bytes())).unwrap();
        assert_eq!(k.public(), back.public());
        assert!(parse_secret_key("abcd").is_err());
    }
}
