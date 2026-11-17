//! Just enough argument parsing for the two binaries: named values and flags
//! pulled out of the argument list, then a check that nothing is left over.

use anyhow::{anyhow, bail, Result};

pub struct Args(Vec<String>);

impl Args {
    pub fn new(args: Vec<String>) -> Self {
        Self(args)
    }

    pub fn value(&mut self, name: &str) -> Result<Option<String>> {
        match self.0.iter().position(|a| a == name) {
            None => Ok(None),
            Some(i) => {
                if i + 1 >= self.0.len() {
                    bail!("{name} needs a value");
                }
                let v = self.0.remove(i + 1);
                self.0.remove(i);
                Ok(Some(v))
            }
        }
    }

    /// Every occurrence of a repeatable option.
    pub fn values(&mut self, name: &str) -> Result<Vec<String>> {
        let mut out = Vec::new();
        while let Some(v) = self.value(name)? {
            out.push(v);
        }
        Ok(out)
    }

    pub fn flag(&mut self, name: &str) -> bool {
        match self.0.iter().position(|a| a == name) {
            None => false,
            Some(i) => {
                self.0.remove(i);
                true
            }
        }
    }

    pub fn require(&mut self, name: &str) -> Result<String> {
        self.value(name)?
            .ok_or_else(|| anyhow!("{name} is required"))
    }

    pub fn done(self) -> Result<()> {
        if self.0.is_empty() {
            Ok(())
        } else {
            bail!("unexpected arguments: {}", self.0.join(" "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(v: &[&str]) -> Args {
        Args::new(v.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn values_flags_and_leftovers() {
        let mut x = a(&["--k", "v", "--f", "--k", "w", "rest"]);
        assert_eq!(x.values("--k").unwrap(), ["v", "w"]);
        assert!(x.flag("--f"));
        assert!(!x.flag("--f"));
        assert!(x.done().is_err());
        assert!(a(&["--k"]).value("--k").is_err());
        assert!(a(&[]).require("--k").is_err());
    }
}
