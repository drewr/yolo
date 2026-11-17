//! Which sandbox (iroh endpoint id) may reach which hosts, and with which
//! sealed secret.
//!
//! ```toml
//! [[sandbox]]
//! id = "<64 hex characters: the sandbox proxy's endpoint id>"
//! name = "agent-1"                       # optional, for humans
//! rules = [
//!   { host = "slack.com", secret = "slack" },
//!   { host = "*.googleapis.com", secret = "google", params = { dst = "X-Goog-Api-Key", fmt = "%s" } },
//! ]
//! ```
//!
//! `params` go to tokenizer after the sealed secret (`dst` and `fmt` are the
//! ones its inject processor reads). A host with no matching rule is refused.

use std::collections::{BTreeMap, HashMap};
use std::str::FromStr;

use anyhow::{bail, Context, Result};
use iroh::EndpointId;
use serde::Deserialize;
use yolo_broker_wire::HostPattern;

#[derive(Debug, Clone)]
pub struct Rule {
    pub pattern: HostPattern,
    pub secret: String,
    pub params: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default)]
pub struct Sandbox {
    pub name: Option<String>,
    pub rules: Vec<Rule>,
}

#[derive(Debug, Clone, Default)]
pub struct Policy {
    sandboxes: HashMap<EndpointId, Sandbox>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileDoc {
    #[serde(default)]
    sandbox: Vec<FileSandbox>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileSandbox {
    id: String,
    name: Option<String>,
    #[serde(default)]
    rules: Vec<FileRule>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileRule {
    host: String,
    secret: String,
    #[serde(default)]
    params: BTreeMap<String, String>,
}

/// Secret ids name files in the file store, so keep them to a safe alphabet.
pub fn valid_secret_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && !id.starts_with('.')
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

impl Policy {
    pub fn parse(text: &str) -> Result<Self> {
        let doc: FileDoc = toml::from_str(text).context("policy.toml")?;
        let mut sandboxes = HashMap::new();
        for s in doc.sandbox {
            let id = EndpointId::from_str(s.id.trim())
                .map_err(|e| anyhow::anyhow!("bad sandbox id {:?}: {e}", s.id))?;
            let mut rules = Vec::new();
            for r in s.rules {
                if !valid_secret_id(&r.secret) {
                    bail!("bad secret id {:?}", r.secret);
                }
                rules.push(Rule {
                    pattern: HostPattern::parse(&r.host)?,
                    secret: r.secret,
                    params: r.params,
                });
            }
            if sandboxes
                .insert(
                    id,
                    Sandbox {
                        name: s.name,
                        rules,
                    },
                )
                .is_some()
            {
                bail!("sandbox {id} appears twice");
            }
        }
        Ok(Self { sandboxes })
    }

    pub fn knows(&self, node: &EndpointId) -> bool {
        self.sandboxes.contains_key(node)
    }

    pub fn name(&self, node: &EndpointId) -> Option<&str> {
        self.sandboxes.get(node)?.name.as_deref()
    }

    /// The most specific rule of `node` matching `host:port`. None for an
    /// unknown node or an unlisted host.
    pub fn lookup(&self, node: &EndpointId, host: &str, port: u16) -> Option<&Rule> {
        self.sandboxes
            .get(node)?
            .rules
            .iter()
            .filter(|r| r.pattern.matches(host, port))
            .max_by_key(|r| r.pattern.specificity())
    }

    /// The patterns `node` may use, in canonical form. None for an unknown node.
    pub fn patterns(&self, node: &EndpointId) -> Option<Vec<String>> {
        Some(
            self.sandboxes
                .get(node)?
                .rules
                .iter()
                .map(|r| r.pattern.to_string())
                .collect(),
        )
    }

    pub fn secret_ids(&self) -> impl Iterator<Item = &str> {
        self.sandboxes
            .values()
            .flat_map(|s| s.rules.iter().map(|r| r.secret.as_str()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id() -> EndpointId {
        iroh::SecretKey::generate().public()
    }

    fn policy(a: EndpointId, b: EndpointId) -> Policy {
        Policy::parse(&format!(
            r#"
[[sandbox]]
id = "{a}"
name = "one"
rules = [
  {{ host = "*.example.com", secret = "wild" }},
  {{ host = "api.example.com", secret = "exact", params = {{ dst = "X-Key" }} }},
  {{ host = "localhost:8443", secret = "local" }},
]

[[sandbox]]
id = "{b}"
rules = [{{ host = "other.test", secret = "other" }}]
"#
        ))
        .unwrap()
    }

    #[test]
    fn exact_beats_wildcard_and_carries_params() {
        let (a, b) = (id(), id());
        let p = policy(a, b);
        let r = p.lookup(&a, "api.example.com", 443).unwrap();
        assert_eq!(r.secret, "exact");
        assert_eq!(r.params["dst"], "X-Key");
        assert_eq!(p.lookup(&a, "x.example.com", 443).unwrap().secret, "wild");
    }

    #[test]
    fn hosts_are_per_sandbox() {
        let (a, b) = (id(), id());
        let p = policy(a, b);
        assert!(p.lookup(&b, "api.example.com", 443).is_none());
        assert_eq!(p.lookup(&b, "other.test", 443).unwrap().secret, "other");
        assert!(p.lookup(&a, "other.test", 443).is_none());
    }

    #[test]
    fn unknown_node_gets_nothing() {
        let p = policy(id(), id());
        let stranger = id();
        assert!(!p.knows(&stranger));
        assert!(p.lookup(&stranger, "api.example.com", 443).is_none());
        assert!(p.patterns(&stranger).is_none());
    }

    #[test]
    fn ports_must_match() {
        let (a, b) = (id(), id());
        let p = policy(a, b);
        assert!(p.lookup(&a, "api.example.com", 8443).is_none());
        assert!(p.lookup(&a, "localhost", 8443).is_some());
        assert!(p.lookup(&a, "localhost", 443).is_none());
    }

    #[test]
    fn patterns_are_canonical() {
        let (a, b) = (id(), id());
        let p = policy(a, b);
        assert_eq!(
            p.patterns(&a).unwrap(),
            ["*.example.com", "api.example.com", "localhost:8443"]
        );
        assert_eq!(p.name(&a), Some("one"));
        assert_eq!(p.name(&b), None);
    }

    #[test]
    fn rejects_bad_documents() {
        let a = id();
        for bad in [
            "[[sandbox]]\nid = \"nope\"".to_string(),
            format!("[[sandbox]]\nid = \"{a}\"\n[[sandbox]]\nid = \"{a}\""),
            format!("[[sandbox]]\nid = \"{a}\"\nrules = [{{ host = \"a..b\", secret = \"s\" }}]"),
            format!("[[sandbox]]\nid = \"{a}\"\nrules = [{{ host = \"a.b\", secret = \"../s\" }}]"),
            format!("[[sandbox]]\nid = \"{a}\"\nextra = 1"),
        ] {
            assert!(Policy::parse(&bad).is_err(), "{bad}");
        }
        assert!(Policy::parse("").unwrap().sandboxes.is_empty());
    }
}
