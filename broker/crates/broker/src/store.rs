//! Where the broker's state lives. Everything the broker needs to restart
//! unattended comes through [`Store::load`]: tokenizer's address and bearer
//! password, the CA, the policy and the sealed secrets.
//!
//! The trait is one method so a Datum Secret backend (or anything else) stays
//! cheap to add. Tokenizer's open key is not here: the broker can neither
//! open a sealed secret nor read the credential inside it.

use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use zeroize::Zeroizing;

use crate::policy::{valid_secret_id, Policy};

/// No `Debug`: this holds the tokenizer password, the CA key and the sealed
/// secrets, none of which may end up in a log line or a panic message.
pub struct Snapshot {
    /// `http://host:port` of tokenizer.
    pub tokenizer_url: String,
    /// The password whose SHA-256 every sealed secret's `bearer_auth` holds.
    pub tokenizer_password: Zeroizing<String>,
    pub ca_cert_pem: String,
    pub ca_key_pem: Zeroizing<String>,
    pub policy: Policy,
    /// Secret id to its sealed, base64 form.
    pub secrets: HashMap<String, String>,
}

impl Snapshot {
    /// Check the pieces agree: every secret the policy names exists.
    pub fn validate(&self) -> Result<()> {
        for id in self.policy.secret_ids() {
            if !self.secrets.contains_key(id) {
                bail!("policy names secret {id:?}, which the store does not have");
            }
        }
        if !self.tokenizer_url.starts_with("http://") {
            bail!(
                "tokenizer url must be http://host:port, got {:?}",
                self.tokenizer_url
            );
        }
        Ok(())
    }
}

pub trait Store: Send + Sync + 'static {
    fn load(&self) -> impl Future<Output = Result<Snapshot>> + Send;
}

/// A directory (mode 0700; a store that group or other can enter is refused):
///
/// ```text
/// tokenizer-url        http://127.0.0.1:8080
/// tokenizer-password   (0600, enforced on load)
/// ca.pem  ca.key       the CA (ca.key is 0600, enforced on load)
/// policy.toml          see policy.rs
/// secrets/<id>         one sealed secret per file, base64
/// ```
pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Create what is missing: url, password, CA, an empty policy. Existing
    /// files are never overwritten, so this is safe to run again.
    pub fn init(&self, tokenizer_url: &str) -> Result<()> {
        self.init_with(tokenizer_url, crate::ca::DEFAULT_CA_DAYS)
    }

    /// [`Self::init`], with the lifetime of a newly made CA in days.
    pub fn init_with(&self, tokenizer_url: &str, ca_days: u32) -> Result<()> {
        use yolo_broker_wire::{create_private_dir, hex, write_private};
        let d = &self.dir;
        create_private_dir(&d.join("secrets"))?;
        let put = |name: &str, data: &[u8], private: bool| -> Result<()> {
            let path = d.join(name);
            if path.exists() {
                return Ok(());
            }
            if private {
                write_private(&path, data)
            } else {
                std::fs::write(&path, data).with_context(|| path.display().to_string())
            }
        };
        put(
            "tokenizer-url",
            format!("{tokenizer_url}\n").as_bytes(),
            false,
        )?;
        let mut pw = [0u8; 32];
        crypto_box::aead::rand_core::RngCore::fill_bytes(&mut crypto_box::aead::OsRng, &mut pw);
        put(
            "tokenizer-password",
            format!("{}\n", hex(&pw)).as_bytes(),
            true,
        )?;
        if !d.join("ca.pem").exists() && !d.join("ca.key").exists() {
            let (cert, key) = crate::ca::generate_ca_with("yolo-broker CA", ca_days)?;
            put("ca.pem", cert.as_bytes(), false)?;
            put("ca.key", key.as_bytes(), true)?;
        }
        put("policy.toml", b"# [[sandbox]]\n# id = \"<endpoint id>\"\n# rules = [{ host = \"api.example.com\", secret = \"example\" }]\n", false)?;
        Ok(())
    }

    pub fn put_secret(&self, id: &str, sealed: &str) -> Result<()> {
        if !valid_secret_id(id) {
            bail!("bad secret id {id:?}");
        }
        yolo_broker_wire::write_private(
            &self.dir.join("secrets").join(id),
            format!("{sealed}\n").as_bytes(),
        )
    }

    pub fn read_password(&self) -> Result<Zeroizing<String>> {
        read_private_trim(&self.dir.join("tokenizer-password"))
    }
}

fn read_trim(path: &Path) -> Result<String> {
    Ok(std::fs::read_to_string(path)
        .with_context(|| path.display().to_string())?
        .trim()
        .to_string())
}

/// A secret file: refused unless group and other have no access to it.
fn read_private_trim(path: &Path) -> Result<Zeroizing<String>> {
    let raw = Zeroizing::new(yolo_broker_wire::read_private(path)?);
    Ok(Zeroizing::new(raw.trim().to_string()))
}

impl Store for FileStore {
    async fn load(&self) -> Result<Snapshot> {
        let dir = self.dir.clone();
        tokio::task::spawn_blocking(move || {
            yolo_broker_wire::check_private_dir(&dir)?;
            let mut secrets = HashMap::new();
            let sdir = dir.join("secrets");
            for entry in std::fs::read_dir(&sdir).with_context(|| sdir.display().to_string())? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if valid_secret_id(&name) && entry.file_type()?.is_file() {
                    secrets.insert(name, read_trim(&entry.path())?);
                }
            }
            let snap = Snapshot {
                tokenizer_url: read_trim(&dir.join("tokenizer-url"))?,
                tokenizer_password: read_private_trim(&dir.join("tokenizer-password"))?,
                ca_cert_pem: read_trim(&dir.join("ca.pem"))?,
                ca_key_pem: read_private_trim(&dir.join("ca.key"))?,
                policy: Policy::parse(&read_trim(&dir.join("policy.toml"))?)?,
                secrets,
            };
            snap.validate()?;
            Ok(snap)
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn init_then_load_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let store = FileStore::new(tmp.path().join("s"));
        store.init("http://127.0.0.1:8080").unwrap();
        let snap = store.load().await.unwrap();
        assert_eq!(snap.tokenizer_url, "http://127.0.0.1:8080");
        assert_eq!(snap.tokenizer_password.len(), 64);
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |p: PathBuf| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(store.dir().to_path_buf()), 0o700);
            assert_eq!(mode(store.dir().join("secrets")), 0o700);
            assert_eq!(mode(store.dir().join("ca.key")), 0o600);
            assert_eq!(mode(store.dir().join("tokenizer-password")), 0o600);
        }
        assert!(snap.secrets.is_empty());

        // init again keeps what exists
        store.init("http://other:1").unwrap();
        let again = store.load().await.unwrap();
        assert_eq!(again.tokenizer_url, snap.tokenizer_url);
        assert_eq!(again.tokenizer_password, snap.tokenizer_password);
        assert_eq!(again.ca_cert_pem, snap.ca_cert_pem);
    }

    #[tokio::test]
    async fn policy_naming_a_missing_secret_fails_the_load() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let store = FileStore::new(tmp.path());
        store.init("http://127.0.0.1:8080").unwrap();
        let id = iroh::SecretKey::generate().public();
        std::fs::write(
            tmp.path().join("policy.toml"),
            format!(
                "[[sandbox]]\nid = \"{id}\"\nrules = [{{ host = \"a.test\", secret = \"s\" }}]\n"
            ),
        )
        .unwrap();
        assert!(store.load().await.is_err());
        store.put_secret("s", "c2VhbGVk").unwrap();
        let snap = store.load().await.unwrap();
        assert_eq!(snap.secrets["s"], "c2VhbGVk");
        assert!(store.put_secret("../x", "y").is_err());
    }

    #[tokio::test]
    async fn loose_permissions_fail_the_load() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let store = FileStore::new(tmp.path().join("s"));
        store.init("http://127.0.0.1:8080").unwrap();
        let chmod = |p: PathBuf, m| {
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(m)).unwrap()
        };
        for file in ["ca.key", "tokenizer-password"] {
            let p = store.dir().join(file);
            chmod(p.clone(), 0o640);
            let err = format!("{:#}", store.load().await.err().unwrap());
            assert!(err.contains(file) && err.contains("chmod 600"), "{err}");
            chmod(p, 0o600);
        }
        chmod(store.dir().to_path_buf(), 0o750);
        let err = format!("{:#}", store.load().await.err().unwrap());
        assert!(err.contains("chmod 700"), "{err}");
        chmod(store.dir().to_path_buf(), 0o700);
        assert!(store.load().await.is_ok());
    }
}
