use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use iroh::{EndpointAddr, EndpointId};
use yolo_broker_proxy::{start, Config};
use yolo_broker_wire::cli::Args;
use yolo_broker_wire::{resolve_secret_key, Network};

const USAGE: &str = "\
yolo-broker-proxy: sandbox-side CONNECT proxy for yolo-broker

  yolo-broker-proxy run --broker ID [--broker-addr SOCKADDR]... [--listen ADDR]...
                        [--key-file FILE] [--bind ADDR]... [--direct]
                        [--refresh-secs N] [--first-policy-wait-secs N]
      Listen on each ADDR (default: both 127.0.0.1:3128 and [::1]:3128, the
      second skipped if the host has no IPv6; set HTTPS_PROXY to either).
      --listen may be repeated. --bind (iroh's local address) may be given
      twice, once per IP family; a family without one stays on its wildcard.
      Hosts dialed directly are reached by Happy Eyeballs (IPv6 first, IPv4
      after 250 ms or at once if IPv6 fails). CONNECTs
      to hosts the broker allows this sandbox go over iroh to the broker; the
      rest are spliced directly. --broker defaults to $YOLO_BROKER_ID. The
      iroh secret key comes from $YOLO_PROXY_SECRET_KEY (hex) or --key-file
      ($YOLO_PROXY_KEY_FILE, default ./proxy.key, created if missing).
      --direct disables relays and lookup; give --broker-addr then.
      --refresh-secs (default 60) is how often the policy is refreshed once
      it has loaded. Until the first load the proxy retries every 2 seconds,
      and a CONNECT arriving meanwhile waits up to --first-policy-wait-secs
      (default 30; 0 does not wait) for it before going direct.
  yolo-broker-proxy id [--key-file FILE]
      Print this sandbox's endpoint id, to add to the broker's policy.
";

fn key_file(args: &mut Args) -> Result<PathBuf> {
    Ok(PathBuf::from(
        args.value("--key-file")?
            .or_else(|| std::env::var("YOLO_PROXY_KEY_FILE").ok())
            .unwrap_or_else(|| "proxy.key".into()),
    ))
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("yolo-broker-proxy: {e:#}");
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
        "id" => {
            let kf = key_file(&mut args)?;
            args.done()?;
            println!(
                "{}",
                resolve_secret_key("YOLO_PROXY_SECRET_KEY", &kf)?.public()
            );
            Ok(())
        }
        "run" => {
            let kf = key_file(&mut args)?;
            let broker: EndpointId = args
                .value("--broker")?
                .or_else(|| std::env::var("YOLO_BROKER_ID").ok())
                .context("--broker (or YOLO_BROKER_ID) is required")?
                .parse()
                .map_err(|e| anyhow::anyhow!("bad broker id: {e}"))?;
            let mut addr = EndpointAddr::new(broker);
            for a in args.values("--broker-addr")? {
                addr = addr.with_ip_addr(a.parse().with_context(|| format!("--broker-addr {a}"))?);
            }
            let listen_args = args.values("--listen")?;
            let listen_is_default = listen_args.is_empty();
            let listen = if listen_is_default {
                vec!["127.0.0.1:3128".parse()?, "[::1]:3128".parse()?]
            } else {
                listen_args
                    .iter()
                    .map(|l| l.parse().with_context(|| format!("--listen {l}")))
                    .collect::<Result<Vec<SocketAddr>>>()?
            };
            let bind = args
                .values("--bind")?
                .iter()
                .map(|b| b.parse().with_context(|| format!("--bind {b}")))
                .collect::<Result<Vec<SocketAddr>>>()?;
            let network = if args.flag("--direct") {
                Network::Direct
            } else {
                Network::Default
            };
            let refresh = args
                .value("--refresh-secs")?
                .map(|s| s.parse::<u64>())
                .transpose()
                .context("--refresh-secs")?
                .unwrap_or(60);
            let first_policy_wait = args
                .value("--first-policy-wait-secs")?
                .map(|s| s.parse::<u64>())
                .transpose()
                .context("--first-policy-wait-secs")?
                .unwrap_or(30);
            args.done()?;
            if refresh == 0 {
                bail!("--refresh-secs must be positive");
            }
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::try_from_default_env()
                        .unwrap_or_else(|_| "info".into()),
                )
                .with_writer(std::io::stderr)
                .init();
            let proxy = start(Config {
                secret: resolve_secret_key("YOLO_PROXY_SECRET_KEY", &kf)?,
                broker: addr,
                network,
                listen,
                listen_is_default,
                bind,
                refresh: Duration::from_secs(refresh),
                first_policy_retry: Duration::from_secs(2),
                first_policy_wait: Duration::from_secs(first_policy_wait),
                rpc_timeout: Duration::from_secs(10),
            })
            .await?;
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
            proxy.shutdown().await;
            Ok(())
        }
        other => bail!("unknown command {other:?}\n\n{USAGE}"),
    }
}
