//! Sealing a secret to tokenizer's public key, in tokenizer's exact format:
//! a libsodium sealed box (`crypto_box_seal`) over the secret's JSON, base64
//! (standard alphabet, padded) for the `Proxy-Tokenizer` header.
//!
//! The broker never holds tokenizer's open key, so it can seal but not unseal.

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use crypto_box::aead::OsRng;
use crypto_box::PublicKey;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Seal `json` to `seal_key_hex`, the hex public key tokenizer logs at startup
/// (`tokenizer sealkey` prints the same).
pub fn seal(seal_key_hex: &str, json: &[u8]) -> Result<String> {
    let key: [u8; 32] = yolo_broker_wire::unhex(seal_key_hex)
        .context("seal key")?
        .try_into()
        .map_err(|v: Vec<u8>| anyhow!("bad public key size: {}", v.len()))?;
    let sealed = PublicKey::from(key)
        .seal(&mut OsRng, json)
        .map_err(|e| anyhow!("sealing failed: {e}"))?;
    Ok(STANDARD.encode(sealed))
}

/// `bearer_auth.digest` for a tokenizer password: base64 of its SHA-256.
pub fn password_digest(password: &str) -> String {
    STANDARD.encode(Sha256::digest(password.as_bytes()))
}

/// A secret must say where it may be used: a non-empty `allowed_hosts`, each
/// entry exactly as the broker will send it to tokenizer as `Host` (lowercase;
/// `host` for port 443, `host:port` otherwise; IPv6 in brackets), because
/// tokenizer compares them as strings. A secret with no list would go to
/// whatever host the policy ever names.
fn check_allowed_hosts(obj: &serde_json::Map<String, Value>) -> Result<()> {
    let hosts = match obj.get("allowed_hosts") {
        Some(Value::Array(a)) if !a.is_empty() => a,
        _ => bail!("secret needs a non-empty \"allowed_hosts\" list naming the hosts it is for"),
    };
    for h in hosts {
        let h = h
            .as_str()
            .ok_or_else(|| anyhow!("allowed_hosts entries must be strings"))?;
        let (host, port) = yolo_broker_wire::split_authority(h)
            .with_context(|| format!("allowed_hosts entry {h:?}"))?;
        let canonical = if port == yolo_broker_wire::DEFAULT_PORT {
            yolo_broker_wire::Host::parse(&host)?.bracketed()
        } else {
            yolo_broker_wire::format_authority(&host, port)
        };
        if canonical != h {
            bail!("allowed_hosts entry {h:?} would never match; write it as {canonical:?}");
        }
    }
    Ok(())
}

/// Parse a secret's JSON and, when it has no `bearer_auth`, bind it to the
/// broker's tokenizer password. Rejects a secret without `allowed_hosts`.
pub fn prepare_secret(json: &str, password: Option<&str>) -> Result<Vec<u8>> {
    let mut v: Value = serde_json::from_str(json).context("secret is not JSON")?;
    let obj = v
        .as_object_mut()
        .ok_or_else(|| anyhow!("secret must be a JSON object"))?;
    check_allowed_hosts(obj)?;
    if !obj.contains_key("bearer_auth") {
        match password {
            Some(p) => {
                obj.insert(
                    "bearer_auth".into(),
                    json!({ "digest": password_digest(p) }),
                );
            }
            None => bail!("secret has no bearer_auth and no store password to derive one from"),
        }
    }
    Ok(serde_json::to_vec(&v)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crypto_box::SecretKey;

    fn keypair() -> (SecretKey, String) {
        let sk = SecretKey::generate(&mut OsRng);
        let pk_hex = yolo_broker_wire::hex(sk.public_key().as_bytes());
        (sk, pk_hex)
    }

    #[test]
    fn sealed_box_layout_and_roundtrip() {
        let (sk, pk) = keypair();
        let msg = br#"{"inject_processor":{"token":"t"}}"#;
        let b64 = seal(&pk, msg).unwrap();
        let raw = STANDARD.decode(&b64).unwrap();
        // libsodium sealed box: ephemeral public key (32) || ciphertext || MAC (16)
        assert_eq!(raw.len(), 32 + msg.len() + 16);
        assert_eq!(sk.unseal(&raw).unwrap(), msg);
    }

    #[test]
    fn sealing_is_randomized() {
        let (_, pk) = keypair();
        assert_ne!(seal(&pk, b"x").unwrap(), seal(&pk, b"x").unwrap());
    }

    #[test]
    fn wrong_key_cannot_open() {
        let (_, pk) = keypair();
        let (other, _) = keypair();
        let raw = STANDARD.decode(seal(&pk, b"x").unwrap()).unwrap();
        assert!(other.unseal(&raw).is_err());
    }

    #[test]
    fn rejects_bad_keys() {
        assert!(seal("zz", b"x").is_err());
        assert!(seal("abcd", b"x").is_err());
    }

    #[test]
    fn digest_is_base64_sha256() {
        // sha256("password")
        assert_eq!(
            password_digest("password"),
            "XohImNooBHFR0OVvjcYpJ3NgPQ1qq73WKhHvch0VQtg="
        );
    }

    #[test]
    fn prepare_adds_bearer_auth_only_when_missing() {
        let out = prepare_secret(
            r#"{"inject_processor":{"token":"t"},"allowed_hosts":["a.test"]}"#,
            Some("password"),
        )
        .unwrap();
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(
            v["bearer_auth"]["digest"],
            "XohImNooBHFR0OVvjcYpJ3NgPQ1qq73WKhHvch0VQtg="
        );
        let kept = prepare_secret(
            r#"{"bearer_auth":{"digest":"AA=="},"allowed_hosts":["a.test"]}"#,
            Some("password"),
        )
        .unwrap();
        let v: Value = serde_json::from_slice(&kept).unwrap();
        assert_eq!(v["bearer_auth"]["digest"], "AA==");
        assert!(prepare_secret(r#"{"allowed_hosts":["a.test"]}"#, None).is_err());
        assert!(prepare_secret("[]", Some("p")).is_err());
    }

    #[test]
    fn a_secret_must_name_its_hosts() {
        let with = |hosts: &str| {
            prepare_secret(
                &format!(r#"{{"inject_processor":{{"token":"t"}},{hosts}}}"#),
                Some("p"),
            )
        };
        // no list, an empty list, the wrong type
        for bad in [
            "",
            r#""allowed_hosts":[]"#,
            r#""allowed_hosts":null"#,
            r#""allowed_hosts":"a.test""#,
            r#""allowed_hosts":[1]"#,
            r#""allowed_hosts":[""]"#,
            r#""allowed_hosts":["*.a.test"]"#,
            r#""allowed_hosts":["A.test"]"#,
            r#""allowed_hosts":["a.test:443"]"#,
            r#""allowed_hosts":["a.test?x"]"#,
            r#""allowed_hosts":["::1"]"#,
            r#""allowed_hosts":["[0:0:0:0:0:0:0:1]"]"#,
            r#""allowed_hosts":["a.test","b.test:0"]"#,
            r#""allowed_hosts_pattern":"a""#,
        ] {
            assert!(with(bad).is_err(), "{bad}");
        }
        for good in [
            r#""allowed_hosts":["a.test"]"#,
            r#""allowed_hosts":["a.test","b.test:8443"]"#,
            r#""allowed_hosts":["[::1]","[::1]:8443","192.0.2.1"]"#,
        ] {
            assert!(with(good).is_ok(), "{good}");
        }
    }
}
