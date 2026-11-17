//! Direct dials for hosts that do not go through the broker: Happy Eyeballs
//! (RFC 8305), so IPv6 is tried first and IPv4 takes over quickly when IPv6 is
//! broken, and neither family can stall the other.

use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::net::TcpStream;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};

/// Pause before starting the next attempt while earlier ones are pending
/// (RFC 8305 section 5, "Connection Attempt Delay": 250 ms).
pub const STAGGER: Duration = Duration::from_millis(250);

/// One attempt, connect to done.
pub const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(10);

/// Name resolution.
pub const RESOLVE_TIMEOUT: Duration = Duration::from_secs(10);

/// Interleave address families, IPv6 first: v6, v4, v6, v4, ... Order within a
/// family is kept (the resolver already sorted it).
pub fn interleave(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let (v6, v4): (Vec<_>, Vec<_>) = addrs.into_iter().partition(SocketAddr::is_ipv6);
    let (mut v6, mut v4) = (VecDeque::from(v6), VecDeque::from(v4));
    let mut out = Vec::with_capacity(v6.len() + v4.len());
    while !v6.is_empty() || !v4.is_empty() {
        out.extend(v6.pop_front());
        out.extend(v4.pop_front());
    }
    out
}

/// Race connection attempts to `addrs` (interleaved, IPv6 first): start one,
/// start the next after `stagger` or as soon as the previous one fails, and
/// return the first that connects. The losers are dropped. Each attempt gets
/// `attempt` to finish.
pub async fn race(
    addrs: Vec<SocketAddr>,
    stagger: Duration,
    attempt: Duration,
) -> io::Result<TcpStream> {
    let mut todo: VecDeque<SocketAddr> = interleave(addrs).into();
    let mut set: JoinSet<io::Result<TcpStream>> = JoinSet::new();
    let mut last = io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to");
    let start = |set: &mut JoinSet<_>, addr: SocketAddr| {
        set.spawn(async move {
            timeout(attempt, TcpStream::connect(addr))
                .await
                .unwrap_or_else(|_| Err(io::ErrorKind::TimedOut.into()))
        });
    };
    if let Some(first) = todo.pop_front() {
        start(&mut set, first);
    }
    while !set.is_empty() {
        tokio::select! {
            done = set.join_next() => match done {
                Some(Ok(Ok(stream))) => return Ok(stream),
                Some(Ok(Err(e))) => {
                    last = e;
                    // A failed attempt hands over at once.
                    if let Some(next) = todo.pop_front() {
                        start(&mut set, next);
                    }
                }
                Some(Err(join)) => last = io::Error::other(join),
                None => break,
            },
            _ = sleep(stagger), if !todo.is_empty() => {
                if let Some(next) = todo.pop_front() {
                    start(&mut set, next);
                }
            }
        }
    }
    Err(last)
}

/// Connect to `host:port` (`host` is a name or an unbracketed IP literal).
/// An IP literal is dialed as is; a name is resolved and raced.
pub async fn connect(host: &str, port: u16) -> io::Result<TcpStream> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return race(vec![SocketAddr::new(ip, port)], STAGGER, ATTEMPT_TIMEOUT).await;
    }
    let addrs: Vec<SocketAddr> = timeout(RESOLVE_TIMEOUT, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "name resolution timed out"))??
        .collect();
    race(addrs, STAGGER, ATTEMPT_TIMEOUT).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;
    use tokio::net::TcpListener;

    fn a(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn families_alternate_with_ipv6_first() {
        let got = interleave(vec![
            a("192.0.2.1:1"),
            a("192.0.2.2:1"),
            a("[2001:db8::1]:1"),
            a("192.0.2.3:1"),
            a("[2001:db8::2]:1"),
        ]);
        assert_eq!(
            got,
            [
                a("[2001:db8::1]:1"),
                a("192.0.2.1:1"),
                a("[2001:db8::2]:1"),
                a("192.0.2.2:1"),
                a("192.0.2.3:1"),
            ]
        );
        assert!(interleave(vec![]).is_empty());
        assert_eq!(interleave(vec![a("192.0.2.1:1")]), [a("192.0.2.1:1")]);
    }

    async fn v6_available() -> bool {
        TcpListener::bind("[::1]:0").await.is_ok()
    }

    /// A port nothing listens on: connecting is refused at once.
    async fn dead(ip: &str) -> SocketAddr {
        let l = TcpListener::bind((ip.parse::<IpAddr>().unwrap(), 0))
            .await
            .unwrap();
        let addr = l.local_addr().unwrap();
        drop(l);
        addr
    }

    #[tokio::test]
    async fn ipv4_takes_over_when_ipv6_fails() {
        if !v6_available().await {
            eprintln!("SKIPPED: this host has no ::1");
            return;
        }
        let good = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let want = good.local_addr().unwrap();
        let s = race(vec![dead("::1").await, want], STAGGER, ATTEMPT_TIMEOUT)
            .await
            .unwrap();
        assert_eq!(s.peer_addr().unwrap(), want);
    }

    #[tokio::test]
    async fn ipv6_is_preferred_when_both_work() {
        if !v6_available().await {
            eprintln!("SKIPPED: this host has no ::1");
            return;
        }
        let v6 = TcpListener::bind("[::1]:0").await.unwrap();
        let v4 = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let want = v6.local_addr().unwrap();
        let s = race(
            vec![v4.local_addr().unwrap(), want],
            STAGGER,
            ATTEMPT_TIMEOUT,
        )
        .await
        .unwrap();
        assert_eq!(s.peer_addr().unwrap(), want);
    }

    #[tokio::test]
    async fn a_failure_hands_over_at_once_not_after_the_stagger() {
        let good = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let t = Instant::now();
        // Two IPv4 addresses: first refused, second fine; a huge stagger
        // proves the second started because the first failed.
        let s = race(
            vec![dead("127.0.0.1").await, good.local_addr().unwrap()],
            Duration::from_secs(30),
            ATTEMPT_TIMEOUT,
        )
        .await
        .unwrap();
        assert!(t.elapsed() < Duration::from_secs(5));
        assert_eq!(s.peer_addr().unwrap(), good.local_addr().unwrap());
    }

    #[tokio::test]
    async fn a_slow_attempt_is_raced_after_the_stagger() {
        let good = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let t = Instant::now();
        // 192.0.2.1 (TEST-NET-1) never answers: the first attempt hangs (or
        // fails at once on a host with no route, which is fine too), and the
        // second must win well before the hanging one's own timeout.
        let s = race(
            vec![a("192.0.2.1:9"), good.local_addr().unwrap()],
            Duration::from_millis(100),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(t.elapsed() < Duration::from_secs(5));
        assert_eq!(s.peer_addr().unwrap(), good.local_addr().unwrap());
    }

    #[tokio::test]
    async fn all_failing_reports_an_error() {
        let r = race(vec![dead("127.0.0.1").await], STAGGER, ATTEMPT_TIMEOUT).await;
        assert!(r.is_err());
        assert!(race(vec![], STAGGER, ATTEMPT_TIMEOUT).await.is_err());
    }

    #[tokio::test]
    async fn per_attempt_timeout_applies() {
        let t = Instant::now();
        let r = race(vec![a("192.0.2.1:9")], STAGGER, Duration::from_millis(200)).await;
        assert!(r.is_err());
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn names_and_literals_connect() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        assert!(connect("127.0.0.1", port).await.is_ok());
        assert!(connect("localhost", port).await.is_ok());
        if v6_available().await {
            let l6 = TcpListener::bind("[::1]:0").await.unwrap();
            assert!(connect("::1", l6.local_addr().unwrap().port())
                .await
                .is_ok());
        }
    }
}
