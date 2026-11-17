//! The broker's certificate authority and the leaf certificates it mints.
//!
//! Sandboxes trust the CA; for each tunneled host the broker presents a leaf
//! for exactly that host, signed by the CA. Leaves are cached per host in a
//! bounded LRU, so a hostile sandbox cannot grow it without limit.
//!
//! The CA is not name-constrained. rcgen can write an X.509 NameConstraints
//! extension, but it would have to list the policy's hosts, the policy changes
//! on every SIGHUP, and sandboxes pin `ca.pem`: re-issuing the CA on each
//! policy change is not an option. So a sandbox that trusts this CA trusts it
//! for every name, and whoever holds `ca.key` can impersonate any site to that
//! sandbox. What limits that: `ca.key` is mode 0600 in a 0700 store and is
//! refused when looser, the CA path length is 0 (it can sign leaves, not other
//! CAs), the CA lives one year by default (`yolo-broker init --ca-days`), and
//! the broker never writes the key anywhere but the store.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use anyhow::Context;
use anyhow::{anyhow, Result};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose, SanType,
};
use rustls::crypto::ring;
use rustls::pki_types::PrivateKeyDer;
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use rustls::ServerConfig;
use time::OffsetDateTime;
use yolo_broker_wire::canonical_host;

/// A leaf lives this long; the cache re-mints before it matters.
const LEAF_VALIDITY: time::Duration = time::Duration::days(7);
const LEAF_REUSE: Duration = Duration::from_secs(24 * 3600);

/// How long a newly made CA is valid unless asked otherwise.
pub const DEFAULT_CA_DAYS: u32 = 365;

/// Leaves kept at once unless asked otherwise.
pub const DEFAULT_MAX_LEAVES: usize = 1024;

/// Generate a new CA valid for [`DEFAULT_CA_DAYS`]: (certificate PEM, private
/// key PEM).
pub fn generate_ca(common_name: &str) -> Result<(String, String)> {
    generate_ca_with(common_name, DEFAULT_CA_DAYS)
}

/// Generate a new CA valid for `days` days.
pub fn generate_ca_with(common_name: &str, days: u32) -> Result<(String, String)> {
    if days == 0 {
        return Err(anyhow!("CA lifetime must be at least one day"));
    }
    let key = KeyPair::generate()?;
    let mut params = CertificateParams::default();
    params.distinguished_name = dn(common_name);
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    let now = OffsetDateTime::now_utc();
    params.not_before = now - time::Duration::days(1);
    params.not_after = now + time::Duration::days(i64::from(days));
    let cert = params.self_signed(&key)?;
    Ok((cert.pem(), key.serialize_pem()))
}

fn dn(cn: &str) -> DistinguishedName {
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, cn);
    dn
}

struct Fixed(Arc<CertifiedKey>);

impl std::fmt::Debug for Fixed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Fixed")
    }
}

impl ResolvesServerCert for Fixed {
    fn resolve(&self, _: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        Some(self.0.clone())
    }
}

struct Entry {
    minted: Instant,
    used: u64,
    cfg: Arc<ServerConfig>,
}

/// Least-recently-used, with a cap. Eviction is a scan: the cap is small and
/// a miss already costs a key generation and a signature.
struct Cache {
    map: HashMap<String, Entry>,
    clock: u64,
    cap: usize,
}

impl Cache {
    fn get(&mut self, host: &str) -> Option<Arc<ServerConfig>> {
        self.clock += 1;
        let e = self.map.get_mut(host)?;
        if e.minted.elapsed() >= LEAF_REUSE {
            return None;
        }
        e.used = self.clock;
        Some(e.cfg.clone())
    }

    /// Keep `cfg` for `host`, unless a fresh one got there first (then that
    /// one wins, so every caller shares it). Returns the one in the cache.
    fn put(&mut self, host: &str, cfg: Arc<ServerConfig>) -> Arc<ServerConfig> {
        if let Some(cached) = self.get(host) {
            return cached;
        }
        if !self.map.contains_key(host) && self.map.len() >= self.cap {
            let victim = self
                .map
                .iter()
                .min_by_key(|(_, e)| (e.minted.elapsed() < LEAF_REUSE, e.used))
                .map(|(k, _)| k.clone());
            if let Some(k) = victim {
                self.map.remove(&k);
            }
        }
        self.clock += 1;
        self.map.insert(
            host.to_string(),
            Entry {
                minted: Instant::now(),
                used: self.clock,
                cfg: cfg.clone(),
            },
        );
        cfg
    }
}

pub struct Ca {
    issuer: Issuer<'static, KeyPair>,
    cache: Mutex<Cache>,
}

impl Ca {
    pub fn load(cert_pem: &str, key_pem: &str) -> Result<Self> {
        Self::load_with(cert_pem, key_pem, DEFAULT_MAX_LEAVES)
    }

    /// Load the CA, keeping at most `max_leaves` minted leaves (at least one).
    pub fn load_with(cert_pem: &str, key_pem: &str, max_leaves: usize) -> Result<Self> {
        let key = KeyPair::from_pem(key_pem).context("CA key")?;
        let issuer = Issuer::from_ca_cert_pem(cert_pem, key).context("CA certificate")?;
        Ok(Self {
            issuer,
            cache: Mutex::new(Cache {
                map: HashMap::new(),
                clock: 0,
                cap: max_leaves.max(1),
            }),
        })
    }

    /// Leaves currently cached.
    pub fn cached(&self) -> usize {
        self.lock().map.len()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Cache> {
        self.cache.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A TLS server config for `host`: one leaf for exactly that host, and
    /// only `http/1.1` in ALPN. `host` is validated first (so its length is
    /// capped and nothing but a DNS name or an IP literal gets a certificate).
    /// The lock is not held while minting.
    pub fn server_config(&self, host: &str) -> Result<Arc<ServerConfig>> {
        let host = canonical_host(host)?;
        if let Some(cfg) = self.lock().get(&host) {
            return Ok(cfg);
        }
        let minted = Arc::new(self.mint(&host)?);
        Ok(self.lock().put(&host, minted))
    }

    fn mint(&self, host: &str) -> Result<ServerConfig> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::default();
        // A CommonName is at most 64 bytes; the SAN is what clients check.
        params.distinguished_name = dn(if host.len() <= 64 {
            host
        } else {
            "yolo-broker leaf"
        });
        params.subject_alt_names = vec![match host.parse::<IpAddr>() {
            Ok(ip) => SanType::IpAddress(ip),
            Err(_) => SanType::DnsName(host.to_string().try_into().map_err(|e| anyhow!("{e:?}"))?),
        }];
        params.is_ca = IsCa::NoCa;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let now = OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::hours(1);
        params.not_after = now + LEAF_VALIDITY;
        let cert = params.signed_by(&key, &self.issuer)?;

        let der = PrivateKeyDer::try_from(key.serialize_der()).map_err(|e| anyhow!("{e}"))?;
        let signing = ring::sign::any_supported_type(&der)?;
        let certified = Arc::new(CertifiedKey::new(vec![cert.der().clone()], signing));

        let mut cfg = ServerConfig::builder_with_provider(Arc::new(ring::default_provider()))
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(Fixed(certified)));
        cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
        Ok(cfg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::pem::PemObject;
    use rustls::pki_types::{CertificateDer, ServerName};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn mints_and_caches_per_host() {
        let (cert, key) = generate_ca("test ca").unwrap();
        let ca = Ca::load(&cert, &key).unwrap();
        let a = ca.server_config("api.example.com").unwrap();
        let again = ca.server_config("API.example.com.").unwrap();
        let other = ca.server_config("other.example.com").unwrap();
        assert!(Arc::ptr_eq(&a, &again));
        assert!(!Arc::ptr_eq(&a, &other));
        assert_eq!(a.alpn_protocols, vec![b"http/1.1".to_vec()]);
        assert!(ca.server_config("127.0.0.1").is_ok());
        assert!(ca.server_config("[::1]").is_ok());
    }

    #[test]
    fn the_cache_is_bounded_and_evicts_the_least_recently_used() {
        let (cert, key) = generate_ca("test ca").unwrap();
        let ca = Ca::load_with(&cert, &key, 2).unwrap();
        let a = ca.server_config("a.test").unwrap();
        let b = ca.server_config("b.test").unwrap();
        // touch a, so b is the one to go
        assert!(Arc::ptr_eq(&a, &ca.server_config("a.test").unwrap()));
        let _c = ca.server_config("c.test").unwrap();
        assert_eq!(ca.cached(), 2);
        assert!(Arc::ptr_eq(&a, &ca.server_config("a.test").unwrap()));
        assert!(!Arc::ptr_eq(&b, &ca.server_config("b.test").unwrap()));
        assert_eq!(ca.cached(), 2);
        // a flood of distinct hosts stays at the cap
        for i in 0..50 {
            ca.server_config(&format!("h{i}.test")).unwrap();
        }
        assert_eq!(ca.cached(), 2);
    }

    #[test]
    fn hosts_that_are_not_hosts_get_no_certificate() {
        let (cert, key) = generate_ca("test ca").unwrap();
        let ca = Ca::load(&cert, &key).unwrap();
        for bad in [
            "",
            "a b",
            "evil.com?.example.com",
            "*.example.com",
            &"a".repeat(300),
        ] {
            assert!(ca.server_config(bad).is_err(), "{bad:?}");
        }
        assert_eq!(ca.cached(), 0);
    }

    fn client(ca_pem: &str) -> tokio_rustls::TlsConnector {
        let mut roots = rustls::RootCertStore::empty();
        for c in CertificateDer::pem_slice_iter(ca_pem.as_bytes()) {
            roots.add(c.unwrap()).unwrap();
        }
        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tokio_rustls::TlsConnector::from(Arc::new(cfg))
    }

    /// A TLS handshake in memory: the leaf minted for `served`, checked by a
    /// client that believes it is talking to `expected`.
    async fn handshake(ca: &Ca, ca_pem: &str, served: &str, expected: &str) -> Result<()> {
        let (c, s) = tokio::io::duplex(16 * 1024);
        let acceptor = tokio_rustls::TlsAcceptor::from(ca.server_config(served)?);
        let server = tokio::spawn(async move {
            let mut tls = acceptor.accept(s).await?;
            tls.write_all(b"k").await?;
            tls.flush().await?;
            let mut b = [0u8; 1];
            let _ = tls.read(&mut b).await;
            Ok::<_, std::io::Error>(())
        });
        let name = ServerName::try_from(expected.to_string())?;
        let mut tls = client(ca_pem).connect(name, c).await?;
        let mut b = [0u8; 1];
        tls.read_exact(&mut b).await?;
        drop(tls);
        let _ = server.await;
        Ok(())
    }

    #[tokio::test]
    async fn leaf_certificates_carry_the_right_san() {
        let (cert, key) = generate_ca("test ca").unwrap();
        let ca = Ca::load(&cert, &key).unwrap();
        for host in [
            "api.example.com",
            "127.0.0.1",
            "::1",
            "2001:db8::1",
            "fd00::1234",
        ] {
            handshake(&ca, &cert, host, host)
                .await
                .unwrap_or_else(|e| panic!("{host}: {e:#}"));
        }
        // an IPv6 leaf is for that address only
        assert!(handshake(&ca, &cert, "::1", "::2").await.is_err());
        assert!(handshake(&ca, &cert, "::1", "127.0.0.1").await.is_err());
        assert!(handshake(&ca, &cert, "::1", "localhost").await.is_err());
        assert!(handshake(&ca, &cert, "api.example.com", "::1")
            .await
            .is_err());
        // and a different CA's leaf is not trusted
        let (other, _) = generate_ca("other").unwrap();
        assert!(handshake(&ca, &other, "::1", "::1").await.is_err());
    }

    #[test]
    fn the_ca_lives_a_year_by_default_and_is_configurable() {
        let (cert, _) = generate_ca("c").unwrap();
        let (long, _) = generate_ca_with("c", 3650).unwrap();
        let der = |pem: &str| CertificateDer::from_pem_slice(pem.as_bytes()).unwrap();
        assert!(generate_ca_with("c", 0).is_err());
        let days = |pem: &str| {
            let der = der(pem);
            let (_, x) = x509_parser::parse_x509_certificate(&der).unwrap();
            (x.validity().not_after.timestamp() - x.validity().not_before.timestamp()) / 86_400
        };
        assert_eq!(days(&cert), 366);
        assert_eq!(days(&long), 3651);
    }

    #[test]
    fn rejects_garbage() {
        let (cert, _) = generate_ca("a").unwrap();
        assert!(Ca::load("junk", "junk").is_err());
        assert!(Ca::load(&cert, "junk").is_err());
    }
}
