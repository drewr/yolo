//! Timeouts and caps, so a sandbox (hostile, remember) cannot hold the broker's
//! sockets, tasks and memory by being slow or by being many.

use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

#[derive(Debug, Clone)]
pub struct Limits {
    /// A sandbox's control frame must arrive this soon after it opens a stream.
    pub control_read: Duration,
    /// The TLS handshake with the sandbox.
    pub tls_accept: Duration,
    /// A request's headers, once the sandbox starts one (hyper's header read
    /// timeout). It also ends a keep-alive tunnel that sits idle between
    /// requests, so a sandbox opens a new tunnel for each burst.
    pub header_read: Duration,
    /// A tunnel that moves no byte in either direction for this long is cut,
    /// whatever it is waiting for.
    pub idle: Duration,
    /// Connecting to tokenizer.
    pub tokenizer_connect: Duration,
    /// Sending the request to tokenizer and getting the response headers back.
    pub tokenizer_request: Duration,
    /// Streams in flight at once, all sandboxes together.
    pub max_streams: usize,
    /// Streams in flight at once, per sandbox. Also the QUIC limit on open
    /// bi-streams per connection.
    pub max_streams_per_node: usize,
    /// Leaf certificates kept.
    pub max_leaves: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            control_read: Duration::from_secs(10),
            tls_accept: Duration::from_secs(10),
            header_read: Duration::from_secs(30),
            idle: Duration::from_secs(300),
            tokenizer_connect: Duration::from_secs(5),
            tokenizer_request: Duration::from_secs(120),
            max_streams: 256,
            max_streams_per_node: 32,
            max_leaves: crate::ca::DEFAULT_MAX_LEAVES,
        }
    }
}

/// Wraps an I/O object and records when a byte last moved through it, for
/// [`idle_watch`].
pub struct Tracked<T> {
    inner: T,
    last: Arc<AtomicU64>,
    epoch: Instant,
}

/// What [`idle_watch`] reads.
#[derive(Clone)]
pub struct Activity {
    last: Arc<AtomicU64>,
    epoch: Instant,
}

impl<T> Tracked<T> {
    pub fn new(inner: T) -> (Self, Activity) {
        let last = Arc::new(AtomicU64::new(0));
        let epoch = Instant::now();
        (
            Self {
                inner,
                last: last.clone(),
                epoch,
            },
            Activity { last, epoch },
        )
    }

    fn touch(&self) {
        self.last
            .store(self.epoch.elapsed().as_millis() as u64, Ordering::Relaxed);
    }
}

impl<T: AsyncRead + Unpin> AsyncRead for Tracked<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let r = Pin::new(&mut self.inner).poll_read(cx, buf);
        if matches!(r, Poll::Ready(Ok(()))) && buf.filled().len() > before {
            self.touch();
        }
        r
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for Tracked<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let r = Pin::new(&mut self.inner).poll_write(cx, buf);
        if matches!(r, Poll::Ready(Ok(n)) if n > 0) {
            self.touch();
        }
        r
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// Resolves once no byte has moved through the [`Tracked`] object for `idle`.
pub async fn idle_watch(a: Activity, idle: Duration) {
    loop {
        let last = Duration::from_millis(a.last.load(Ordering::Relaxed));
        let quiet = a.epoch.elapsed().saturating_sub(last);
        if quiet >= idle {
            return;
        }
        tokio::time::sleep(idle - quiet).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn a_silent_connection_is_idle_and_traffic_resets_the_clock() {
        let (a, mut b) = tokio::io::duplex(64);
        let (mut a, act) = Tracked::new(a);
        let idle = Duration::from_millis(300);

        // Bytes in either direction keep it alive past one idle period...
        let watch = tokio::spawn(idle_watch(act, idle));
        let t0 = Instant::now();
        for _ in 0..4 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            b.write_all(b"x").await.unwrap();
            let mut one = [0u8; 1];
            a.read_exact(&mut one).await.unwrap();
        }
        assert!(
            !watch.is_finished(),
            "still active after {:?}",
            t0.elapsed()
        );
        // ...and silence ends it.
        tokio::time::timeout(Duration::from_secs(3), watch)
            .await
            .expect("idle_watch resolves")
            .unwrap();
        assert!(t0.elapsed() >= Duration::from_millis(600));
    }
}
