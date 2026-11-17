use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use tracing::{error, info};
use yolo_broker::limits::Limits;
use yolo_broker::server::Broker;
use yolo_broker::store::{FileStore, Store};
use yolo_broker::{seal, server};
use yolo_broker_wire::cli::Args;
use yolo_broker_wire::{bind_endpoint, resolve_secret_key, Network, ALPN};

const USAGE: &str = "\
yolo-broker: credential broker for sandboxed agents

  yolo-broker init  --store DIR [--tokenizer-url URL] [--ca-days N]
      Create the store (mode 0700): tokenizer url (default
      http://127.0.0.1:8080, or http://[::1]:8080), a bearer password, a CA
      (valid N days, default 365), an empty policy. Never overwrites.
  yolo-broker serve --store DIR [--key-file FILE] [--bind ADDR]... [--direct]
                    [--log-format json|text] [--max-streams N]
                    [--max-streams-per-node N] [--leaf-cache N]
      Run the broker. SIGHUP reloads the store (revocation). The iroh secret
      key comes from $YOLO_BROKER_SECRET_KEY (hex) or --key-file (default
      ./broker.key, created if missing; refused if group/other can read it).
      --bind may be given twice, once per IP family (127.0.0.1:4000 and
      [::1]:4000); a family without one stays on its wildcard (0.0.0.0, [::]).
      --direct disables relays and address lookup: sandboxes must dial a
      --bind address. Limits: --max-streams (default 256) and
      --max-streams-per-node (32) cap concurrent tunnels and requests;
      --leaf-cache (1024) caps cached leaf certificates.
  yolo-broker id    [--key-file FILE]
      Print the broker's endpoint id.
  yolo-broker seal  --seal-key HEX (--json TEXT | --json-file FILE|-)
                    [--store DIR [--id NAME]]
      Seal a tokenizer secret to tokenizer's public key (HEX is the seal_key
      tokenizer logs at startup). With --store, a secret without bearer_auth
      is bound to the store's tokenizer password; with --id the sealed secret
      is also written to the store. Prints the sealed secret.
";

fn init_logging(format: &str) -> Result<()> {
    // The audit trail is not subject to $RUST_LOG: it is always on.
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"))
        .add_directive("audit=info".parse()?);
    let b = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr);
    match format {
        "json" => b.json().init(),
        "text" => b.init(),
        other => bail!("unknown log format {other:?}"),
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("yolo-broker: {e:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let mut argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || matches!(argv[0].as_str(), "-h" | "--help" | "help") {
        print!("{USAGE}");
        return Ok(());
    }
    let cmd = argv.remove(0);
    let mut args = Args::new(argv);
    match cmd.as_str() {
        "init" => {
            let store = FileStore::new(args.require("--store")?);
            let url = args
                .value("--tokenizer-url")?
                .unwrap_or_else(|| "http://127.0.0.1:8080".into());
            let ca_days = args
                .value("--ca-days")?
                .map(|d| d.parse::<u32>())
                .transpose()
                .context("--ca-days")?
                .unwrap_or(yolo_broker::ca::DEFAULT_CA_DAYS);
            args.done()?;
            store.init_with(&url, ca_days)?;
            println!("store ready at {}", store.dir().display());
            println!(
                "CA certificate for sandboxes to trust: {}",
                store.dir().join("ca.pem").display()
            );
            Ok(())
        }
        "id" => {
            let key_file = PathBuf::from(
                args.value("--key-file")?
                    .unwrap_or_else(|| "broker.key".into()),
            );
            args.done()?;
            println!(
                "{}",
                resolve_secret_key("YOLO_BROKER_SECRET_KEY", &key_file)?.public()
            );
            Ok(())
        }
        "seal" => {
            let seal_key = args.require("--seal-key")?;
            let json = match (args.value("--json")?, args.value("--json-file")?) {
                (Some(j), None) => j,
                (None, Some(f)) if f == "-" => {
                    let mut s = String::new();
                    std::io::stdin().read_to_string(&mut s)?;
                    s
                }
                (None, Some(f)) => std::fs::read_to_string(&f).with_context(|| f.clone())?,
                _ => bail!("give exactly one of --json and --json-file"),
            };
            let store = args.value("--store")?.map(FileStore::new);
            let id = args.value("--id")?;
            args.done()?;
            let password = store.as_ref().map(|s| s.read_password()).transpose()?;
            let sealed = seal::seal(
                &seal_key,
                &seal::prepare_secret(&json, password.as_ref().map(|p| p.as_str()))?,
            )?;
            match (&store, &id) {
                (Some(s), Some(id)) => s.put_secret(id, &sealed)?,
                (None, Some(_)) => bail!("--id needs --store"),
                _ => {}
            }
            println!("{sealed}");
            Ok(())
        }
        "serve" => {
            let store = FileStore::new(args.require("--store")?);
            let key_file = PathBuf::from(
                args.value("--key-file")?
                    .unwrap_or_else(|| "broker.key".into()),
            );
            let bind = args
                .values("--bind")?
                .iter()
                .map(|b| b.parse().with_context(|| format!("--bind {b}")))
                .collect::<Result<Vec<SocketAddr>>>()?;
            let mut limits = Limits::default();
            let mut count = |name: &str, into: &mut usize| -> Result<()> {
                if let Some(v) = args.value(name)? {
                    *into = v.parse().with_context(|| name.to_string())?;
                    if *into == 0 {
                        bail!("{name} must be positive");
                    }
                }
                Ok(())
            };
            count("--max-streams", &mut limits.max_streams)?;
            count("--max-streams-per-node", &mut limits.max_streams_per_node)?;
            count("--leaf-cache", &mut limits.max_leaves)?;
            let network = if args.flag("--direct") {
                Network::Direct
            } else {
                Network::Default
            };
            let log = args.value("--log-format")?.unwrap_or_else(|| "json".into());
            args.done()?;
            init_logging(&log)?;
            serve(store, key_file, bind, network, limits).await
        }
        other => bail!("unknown command {other:?}\n\n{USAGE}"),
    }
}

async fn serve<S: Store>(
    store: S,
    key_file: PathBuf,
    bind: Vec<SocketAddr>,
    network: Network,
    limits: Limits,
) -> Result<()> {
    let secret = resolve_secret_key("YOLO_BROKER_SECRET_KEY", &key_file)?;
    let broker: std::sync::Arc<Broker<S>> = server::Broker::with_limits(store, limits)
        .await
        .context("loading the store")?;
    let opts = broker.endpoint_opts(bind);
    let endpoint = bind_endpoint(secret, network, vec![ALPN.to_vec()], opts).await?;
    info!(id = %endpoint.id(), addrs = ?endpoint.bound_sockets(), "listening");

    let mut hup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())?;
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let serving = tokio::spawn(broker.clone().serve(endpoint.clone()));
    loop {
        tokio::select! {
            _ = hup.recv() => {
                if let Err(e) = broker.reload().await {
                    error!("reload failed, still enforcing the previous policy: {e:#}");
                }
            }
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    info!("shutting down");
    endpoint.close().await;
    serving.abort();
    Ok(())
}
