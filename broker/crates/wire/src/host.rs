//! The one place a host is validated and canonicalised. Everything that takes a
//! host from outside the process (a policy pattern, a CONNECT target, a `Host`
//! header, a control frame) goes through here, so they all agree on what a
//! host is and on what it is not.
//!
//! A host is a DNS name or an IP literal (IPv4 or IPv6):
//!
//! - A DNS name is LDH labels (letters, digits, hyphen; 1 to 63 bytes; no
//!   leading or trailing hyphen) separated by single dots, at most 253 bytes in
//!   all. It is lowercased and at most one trailing dot is dropped. A name
//!   whose last label is all digits (or `0x` and hex digits) is refused, since
//!   resolvers read `1.2.3`, `0x7f.1` and the like as IPv4 addresses.
//! - An IP literal is parsed by `std::net`. IPv6 is stored unbracketed and in
//!   its compressed form, so `::1` and `0:0:0:0:0:0:0:1` are the same host, and
//!   an IPv4-mapped address is the IPv4 address it maps.
//! - In an authority (`host:port`) an IPv6 literal is bracketed: `[::1]:443`.
//!
//! Everything else (`?#@/`, whitespace, empty labels, `..`, non-ASCII, scoped
//! IPv6) is an error.

use std::fmt;
use std::net::{IpAddr, Ipv6Addr};

use anyhow::{anyhow, bail, Result};

/// The port a bare host or pattern (no `:port`) stands for.
pub const DEFAULT_PORT: u16 = 443;

/// Longest DNS name, without a trailing dot.
pub const MAX_HOST_LEN: usize = 253;

const MAX_LABEL_LEN: usize = 63;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Host {
    /// Lowercase, no trailing dot.
    Dns(String),
    /// Never an IPv4-mapped IPv6 address.
    Ip(IpAddr),
}

impl Host {
    /// Validate and canonicalise one host. IPv6 may be given bare or bracketed.
    pub fn parse(s: &str) -> Result<Host> {
        if let Some(inner) = s.strip_prefix('[') {
            let inner = inner
                .strip_suffix(']')
                .ok_or_else(|| anyhow!("unterminated '[' in host"))?;
            let v6: Ipv6Addr = inner
                .parse()
                .map_err(|_| anyhow!("bracketed host is not an IPv6 address"))?;
            return Ok(Host::Ip(IpAddr::V6(v6).to_canonical()));
        }
        if let Ok(ip) = s.parse::<IpAddr>() {
            return Ok(Host::Ip(ip.to_canonical()));
        }
        dns_name(s).map(Host::Dns)
    }

    pub fn is_dns(&self) -> bool {
        matches!(self, Host::Dns(_))
    }

    /// `host` or `[v6]`, the form that goes in a URI or a `Host` header.
    pub fn bracketed(&self) -> String {
        match self {
            Host::Ip(IpAddr::V6(v6)) => format!("[{v6}]"),
            other => other.to_string(),
        }
    }
}

impl fmt::Display for Host {
    /// The canonical, unbracketed form.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Host::Dns(d) => f.write_str(d),
            Host::Ip(ip) => write!(f, "{ip}"),
        }
    }
}

fn dns_name(s: &str) -> Result<String> {
    let s = s.strip_suffix('.').unwrap_or(s);
    if s.is_empty() {
        bail!("empty host");
    }
    if s.len() > MAX_HOST_LEN {
        bail!("host longer than {MAX_HOST_LEN} bytes");
    }
    let lower = s.to_ascii_lowercase();
    for label in lower.split('.') {
        if label.is_empty() || label.len() > MAX_LABEL_LEN {
            bail!("host has an empty or overlong label");
        }
        if label.starts_with('-') || label.ends_with('-') {
            bail!("host label starts or ends with a hyphen");
        }
        if !label
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            bail!("host has a character outside letters, digits and hyphen");
        }
    }
    let last = lower.rsplit('.').next().unwrap_or("");
    let numeric = last.bytes().all(|b| b.is_ascii_digit());
    let hex = last
        .strip_prefix("0x")
        .is_some_and(|h| !h.is_empty() && h.bytes().all(|b| b.is_ascii_hexdigit()));
    if numeric || hex {
        bail!("host is not a DNS name or an IP address");
    }
    Ok(lower)
}

/// Validate a host (see the module docs) and return its canonical,
/// unbracketed text.
pub fn canonical_host(s: &str) -> Result<String> {
    Host::parse(s).map(|h| h.to_string())
}

/// `host:port`, with an IPv6 literal bracketed. `host` should be canonical.
pub fn format_authority(host: &str, port: u16) -> String {
    if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn parse_port(p: &str) -> Result<u16> {
    if p.is_empty() || p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) {
        bail!("bad port {p:?}");
    }
    match p.parse::<u16>() {
        Ok(0) | Err(_) => bail!("bad port {p:?}"),
        Ok(n) => Ok(n),
    }
}

/// Split `host[:port]` or `[v6][:port]` without validating the host. A
/// bracketed host keeps its brackets, so [`Host::parse`] insists on IPv6.
pub(crate) fn split_host_port(a: &str) -> Result<(&str, Option<u16>)> {
    if let Some(rest) = a.strip_prefix('[') {
        let close = rest
            .find(']')
            .ok_or_else(|| anyhow!("unterminated '[' in {a:?}"))?;
        let host = &a[..close + 2];
        return match &rest[close + 1..] {
            "" => Ok((host, None)),
            after => match after.strip_prefix(':') {
                Some(p) => Ok((host, Some(parse_port(p)?))),
                None => bail!("junk after ']' in {a:?}"),
            },
        };
    }
    match a.split_once(':') {
        None => Ok((a, None)),
        Some((_, p)) if p.contains(':') => {
            bail!("an IPv6 address needs brackets in an authority: {a:?}")
        }
        Some((h, p)) => Ok((h, Some(parse_port(p)?))),
    }
}

/// Split a CONNECT target or `Host` header (`host[:port]`, `[v6][:port]`) into
/// its canonical, unbracketed host and its port (default 443).
pub fn split_authority(authority: &str) -> Result<(String, u16)> {
    let (h, p) = split_host_port(authority)?;
    Ok((canonical_host(h)?, p.unwrap_or(DEFAULT_PORT)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dns_names_are_lowercased_and_lose_one_trailing_dot() {
        assert_eq!(
            canonical_host("API.Example.COM").unwrap(),
            "api.example.com"
        );
        assert_eq!(canonical_host("a.com.").unwrap(), "a.com");
        assert_eq!(canonical_host("localhost").unwrap(), "localhost");
        assert_eq!(canonical_host("a-b.c1.test").unwrap(), "a-b.c1.test");
    }

    #[test]
    fn rejects_everything_that_is_not_ldh() {
        let long_label = "a".repeat(64);
        let long_host = vec!["a".repeat(60); 5].join(".");
        for bad in [
            "",
            ".",
            "a..b",
            "a.com..",
            ".a.com",
            "evil.com?.example.com",
            "evil.com#.example.com",
            "evil.com@x.example.com",
            "a/b",
            "a b",
            "a\tb",
            "a\nb",
            "a.com\r\n",
            "-a.com",
            "a-.com",
            "a_b.com",
            "ex\u{e4}mple.com",
            "a%2eb.com",
            "1.2.3",
            "999.1.1.1",
            "0x7f.1",
            "0x7f.0x1",
            "2130706433",
            "*.a.com",
            "a.com:80",
            long_label.as_str(),
            long_host.as_str(),
            "[a.com]",
            "[1.2.3.4]",
            "[::1",
            "fe80::1%eth0",
            "[fe80::1%eth0]",
        ] {
            assert!(canonical_host(bad).is_err(), "{bad:?}");
        }
        assert!(canonical_host(&"a".repeat(63)).is_ok());
        assert!(canonical_host(&format!("{}.com", "a".repeat(63))).is_ok());
    }

    #[test]
    fn ip_literals_canonicalise() {
        assert_eq!(canonical_host("127.0.0.1").unwrap(), "127.0.0.1");
        assert_eq!(canonical_host("::1").unwrap(), "::1");
        assert_eq!(canonical_host("[::1]").unwrap(), "::1");
        assert_eq!(canonical_host("0:0:0:0:0:0:0:1").unwrap(), "::1");
        assert_eq!(canonical_host("2001:DB8:0::1").unwrap(), "2001:db8::1");
        assert_eq!(canonical_host("::ffff:1.2.3.4").unwrap(), "1.2.3.4");
    }

    #[test]
    fn authority_split() {
        let ok = |s: &str| split_authority(s).unwrap();
        assert_eq!(ok("A.com:8443"), ("a.com".into(), 8443));
        assert_eq!(ok("a.com"), ("a.com".into(), 443));
        assert_eq!(ok("[::1]:8443"), ("::1".into(), 8443));
        assert_eq!(ok("[::1]"), ("::1".into(), 443));
        assert_eq!(ok("[2001:DB8::1]:80"), ("2001:db8::1".into(), 80));
        assert_eq!(ok("1.2.3.4:9"), ("1.2.3.4".into(), 9));
        for bad in [
            "::1",
            "::1:443",
            "[::1]x",
            "[::1]:",
            "[::1]:0",
            "[1.2.3.4]:80",
            "a.com:",
            "a.com:x",
            "a.com:+80",
            "a.com:0",
            "a.com:65536",
            "a.com:80:80",
            ":80",
            "a.com?x=1:80",
        ] {
            assert!(split_authority(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn authority_formatting_brackets_ipv6() {
        assert_eq!(format_authority("a.com", 8443), "a.com:8443");
        assert_eq!(format_authority("::1", 8443), "[::1]:8443");
        assert_eq!(Host::parse("::1").unwrap().bracketed(), "[::1]");
        assert_eq!(Host::parse("a.com").unwrap().bracketed(), "a.com");
    }
}
