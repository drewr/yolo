# yolo-broker

A credential broker for sandboxed coding agents.

Agents need API tokens (Slack, Google, GitHub, ...) but must never hold them:
a prompt-injected agent could leak whatever it holds. The broker runs on a
persistent host next to [superfly/tokenizer](https://github.com/superfly/tokenizer)
and puts the credential on the request after it has left the sandbox. The
sandbox never has the token, so there is nothing to leak.

This is phase 1. It is self-contained: nothing in this directory refers to a
file outside it, so it can move to its own repository as is.

## How a request flows

```
 sandbox                                   jump box
 -------                                   --------
 agent --HTTPS_PROXY--> yolo-broker-proxy ==iroh==> yolo-broker --http--> tokenizer --https--> api.example.com
        (CONNECT)       127.0.0.1:3128      QUIC     terminates TLS      injects the           (real upstream)
                        |                            with its own CA     credential
                        +--> any other host: plain TCP splice, never touches the jump box
```

1. The sandbox sets `HTTPS_PROXY=http://127.0.0.1:3128` (or `http://[::1]:3128`;
   the proxy listens on both) and trusts the broker's CA certificate.
2. `yolo-broker-proxy` asks the broker which host patterns this sandbox may use
   (at startup, then every minute). A CONNECT to a listed host opens an iroh
   bi-stream to the broker. Every other CONNECT is spliced straight to its
   destination.
3. The broker drops a dialer whose endpoint id the policy does not list as soon
   as the QUIC handshake has shown it. For a stream it validates the CONNECT
   host (see "What the broker trusts"), checks it against the policy, mints a
   leaf certificate for the host (cached in a bounded LRU, signed by the broker
   CA, ALPN `http/1.1` only) and terminates TLS.
4. For each HTTP/1.1 request (methods GET, HEAD, POST, PUT, PATCH, DELETE and
   OPTIONS only) it sends plain HTTP to tokenizer on localhost, as
   a proxy request, with `Proxy-Tokenizer: <sealed secret>` and
   `Proxy-Authorization: Bearer <password>`. Tokenizer unseals the secret,
   checks its auth and allowed hosts, injects the credential and calls the
   upstream over HTTPS. The response streams back to the sandbox.
5. One structured log line per request (node id, host, method, path, status)
   goes to the `audit` target. Query strings and credentials are never logged.

The broker holds no credential in the clear. It has the sealed (encrypted)
secrets and tokenizer's bearer password, but not tokenizer's open key, so it
cannot read what it forwards.

## Layout

```
Cargo.toml              workspace
flake.nix               devShell, packages (yolo-broker, tokenizer, tokenizer-test)
crates/wire             ALPN, control messages, host validation and patterns, key files, arg parsing
crates/broker           yolo-broker: store, policy, CA, limits, TLS-terminating relay, seal
  tests/e2e.rs          integration tests against a real tokenizer
  tests/hostile.rs      hostile-sandbox tests, in-process, no tokenizer
crates/proxy            yolo-broker-proxy: the sandbox-side CONNECT proxy
nix/tokenizer-test.go   test-only tokenizer main (see Tests)
```

`nix build ./broker` produces `bin/yolo-broker` and `bin/yolo-broker-proxy`.
`nix develop` gives cargo, rustc, clippy and rustfmt, and sets `TOKENIZER_BIN`
and `TOKENIZER_TEST_BIN` for the integration tests.

## Setting it up

On the jump box, run tokenizer (listening on localhost only) with its open key,
and note the `seal_key` it logs at startup:

```
OPEN_KEY=$(openssl rand -hex 32) LISTEN_ADDRESS=127.0.0.1:8080 tokenizer serve
# ... seal_key=<hex>
```

Create the broker's store, then seal a secret into it:

```
yolo-broker init --store /var/lib/yolo-broker --tokenizer-url http://127.0.0.1:8080
yolo-broker seal --seal-key <hex> --store /var/lib/yolo-broker --id slack \
  --json '{"inject_processor":{"token":"xoxb-..."},"allowed_hosts":["slack.com"]}'
```

`seal` fills in `bearer_auth` from the store's tokenizer password when the JSON
has none, so the secret only works through this broker. The JSON is tokenizer's
own secret format (see its README for other processors). `seal` refuses a secret
without a non-empty `allowed_hosts`, because tokenizer enforces it as the second
lock behind the policy. Each entry must be written the way the broker sends it
as `Host`: lowercase, `host` for port 443 and `host:port` otherwise, IPv6 in
brackets (`[::1]:8443`).

Get the broker's endpoint id, and each sandbox's:

```
yolo-broker id --key-file /var/lib/yolo-broker/broker.key
yolo-broker-proxy id --key-file /sandbox/proxy.key       # in the sandbox
```

Write the policy, `/var/lib/yolo-broker/policy.toml`:

```toml
[[sandbox]]
id = "<the sandbox proxy's endpoint id>"
name = "agent-1"
rules = [
  { host = "slack.com", secret = "slack" },
  { host = "*.googleapis.com", secret = "google", params = { dst = "X-Goog-Api-Key", fmt = "%s" } },
]
```

A host pattern is a DNS name, `*.suffix` (one or more labels, never the bare
suffix; DNS names only), an IPv4 address or a bracketed IPv6 address
(`[2001:db8::1]`), or any of them with `:port`; without a port it means 443.
IP literals are compared as addresses, so `[::1]` and `[0:0:0:0:0:0:0:1]` are the
same pattern. The most specific matching rule wins. `params` ride along after the sealed secret (tokenizer's
`dst` and `fmt`). A host with no rule is refused, and so is an endpoint id that
is not listed.

Run the broker, and the proxy in each sandbox:

```
yolo-broker serve --store /var/lib/yolo-broker --key-file /var/lib/yolo-broker/broker.key
yolo-broker-proxy run --broker <broker id> --key-file /sandbox/proxy.key
export HTTPS_PROXY=http://127.0.0.1:3128 SSL_CERT_FILE=<copy of the store's ca.pem + system roots>
```

### IPv4 and IPv6

Nothing is IPv4-only except traffic between processes on one machine (the
tokenizer URL may be `http://127.0.0.1:8080` or `http://[::1]:8080`).

- CONNECT targets, host patterns, `Host` headers, tokenizer URIs and leaf
  certificate SANs take DNS names, IPv4 addresses and IPv6 addresses
  (`CONNECT [2001:db8::1]:443`; bracketed in authorities, stored unbracketed).
- iroh binds `0.0.0.0` and `[::]` by default. `--bind ADDR` (both binaries)
  replaces the wildcard of ADDR's family only, so give it once per family
  (`--bind 192.0.2.10:4000 --bind [2001:db8::10]:4000`); a second address of one
  family is an error. A family with no `--bind` stays on its wildcard.
- The proxy listens on `127.0.0.1:3128` and `[::1]:3128` unless `--listen` is
  given (repeatable). With the default, a host without IPv6 just skips the
  second; an explicit `--listen` that cannot bind is an error.
- The proxy reaches hosts it splices directly with Happy Eyeballs (RFC 8305):
  IPv6 first, the next address after 250 ms or at once if an attempt fails,
  10 s per attempt.
- IPv6 literal upstreams (`[2001:db8::1]:443`) need a patched tokenizer: stock
  tokenizer splits its dial address at the first `:` and mishandles an IPv6
  literal on port 80 or 443. `nix/tokenizer-ipv6.patch` fixes that and is
  applied to the tokenizer this flake builds, pending the same fix upstream. A
  tokenizer built without it still works for DNS names (which may resolve to
  IPv6) and IPv4 literals.

The sandbox must trust `ca.pem` from the store. Mind the trust variables of
each client (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, ...).

By default both processes use iroh's n0 relays and DNS, so the proxy finds the
broker by its endpoint id alone. `--direct` turns relays and lookup off; then
the broker needs `--bind` and the proxy `--broker-addr`.

Secret keys can come from `$YOLO_BROKER_SECRET_KEY` / `$YOLO_PROXY_SECRET_KEY`
(hex) instead of a file. The proxy's key is its own and shared with nothing else.

### Revocation and restart

`kill -HUP` the broker after editing the store. It reloads everything and
re-checks policy on every request, so tunnels that are already open lose access
at their next request. If the reload fails (bad TOML, a rule naming a missing
secret) the previous state stays in force and the error is logged; that means a
revocation did not happen, so watch for it. To cut a sandbox off at once, remove
it from the policy and SIGHUP.

The broker keeps no state beyond its key file: `serve` reloads the whole store,
so a crash or reboot needs no attention.

## What the broker trusts

The agent in the sandbox is hostile and controls the proxy and every byte it
sends, so the broker trusts only its own policy and the endpoint id the QUIC
handshake proved.

- **One host validator.** Every host (pattern, CONNECT target, `Host` header,
  control frame) goes through `wire::host`: DNS names are LDH labels
  (1 to 63 characters, no leading or trailing hyphen, at most 253 in all),
  lowercased, with at most one trailing dot dropped; a name whose last label is
  all digits or `0x` hex is refused (resolvers read it as an IPv4 address); IP
  literals are parsed by `std::net`. Anything else (`?#@/`, whitespace, empty
  labels, non-ASCII) is refused with "bad host" before it is logged or looked
  up. The tokenizer URI is built from parts, never by pasting strings, and its
  authority is checked to be exactly the validated host.
- **Methods.** GET, HEAD, POST, PUT, PATCH, DELETE and OPTIONS; the rest (TRACE,
  CONNECT, ...) get 405. Request targets are origin-form, or absolute-form for
  the tunnel's own host over `https`; `OPTIONS *` and the rest get 400.
  Exactly one `Host` header, equal to the tunnel's host.
- **Limits.** A control frame must arrive within 10 s, the TLS handshake finish
  within 10 s, request headers within 30 s (which also ends a keep-alive tunnel
  that idles between requests), a tunnel that moves no byte for 5 minutes is cut,
  tokenizer must accept a connection within 5 s and answer within 120 s.
  Concurrent streams are capped globally (`--max-streams`, 256) and per sandbox
  (`--max-streams-per-node`, 32; also iroh's per-connection bi-stream limit),
  past which a stream is refused. The leaf cache holds `--leaf-cache` (1024)
  leaves, least recently used out. Tokenizer is dialed per request, because it
  answers `Connection: close`.
- **Secrets at rest.** The store directory must be mode 0700 and `ca.key`,
  `tokenizer-password` and the iroh key files 0600, or the broker refuses to
  load them; files are written without following symlinks and with the mode set
  on the open file. The password and CA key are zeroized when dropped (the
  copies inside `rcgen`, `ring` and request headers are not), and `Snapshot`
  has no `Debug`.

### Risks the broker does not remove

- **Never give a secret to a host that echoes request headers** (httpbin-style
  debug endpoints, `TRACE`-like behavior, error pages that print the request,
  webhook inspectors). The credential is injected into the request the host
  receives, so the host can hand it to the sandbox in the response.
- **Wildcards over multi-tenant domains hand the secret to whoever can register
  a name under them**: `*.github.io`, `*.amazonaws.com`, `*.run.app`,
  `*.herokuapp.com`, `*.vercel.app` and the like. Use exact hosts, or wildcards
  only over domains you alone control.
- **The CA is not name-constrained.** A constraint would have to list the
  policy's hosts, the policy changes on every SIGHUP, and sandboxes pin
  `ca.pem`, so re-issuing the CA per policy change is not an option. A sandbox
  that trusts the CA trusts it for every name, and whoever has `ca.key` can
  impersonate any site to it. Mitigations: the key's file mode, a CA path length
  of 0, and a one-year lifetime (`yolo-broker init --ca-days N`; renewing means
  re-distributing `ca.pem`).
- **The proxy's iroh key is only a key file.** The broker identifies a sandbox by
  its endpoint id; anything that can read the proxy's key file (or
  `$YOLO_PROXY_SECRET_KEY`) is that sandbox. Binding the key to something more
  (a hardware or platform attestation, a per-boot token) is open.

## Store

`Store` (crates/broker/src/store.rs) has one method, `load`, returning the
tokenizer URL and password, the CA, the policy and the sealed secrets. The file
backend, a directory:

```
tokenizer-url   tokenizer-password (0600)   ca.pem   ca.key (0600)
policy.toml     secrets/<id>                (sealed, base64)
```

A Datum Secret backend only has to implement `load`.

## Tests

`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`
and `nix build ./broker` all pass.

Unit tests cover host validation and patterns (IPv4, IPv6, injection tricks),
policy lookup, the sealed-box layout, the store (file modes), the CA (IPv6 SANs,
cache bound), Happy Eyeballs and the request checks.
`crates/broker/tests/hostile.rs` runs a hostile sandbox against the real broker
over real iroh in-process (bad hosts, methods, targets, timeouts, stream limits,
IPv6), and needs no tokenizer. `crates/broker/tests/e2e.rs` runs a real tokenizer, the real
`yolo-broker` binary, a fake HTTPS upstream with its own CA, and the sandbox
proxy over iroh with relays off, all on localhost. It checks that the upstream
gets the credential and the sandbox never sees it, refusals (host outside the
policy, unknown endpoint id), SIGHUP revocation, restart from the store, direct
splice of other hosts, and that `seal` output is what `tokenizer unseal` opens.

The integration tests need `TOKENIZER_BIN` (stock tokenizer, from the flake)
and `TOKENIZER_TEST_BIN`. Without them they print SKIPPED and pass. The test
binary is the same library behind a different `main` (`nix/tokenizer-test.go`):
stock `tokenizer serve` refuses to dial loopback upstreams, and the fake
upstream lives on loopback. Never deploy it. Tokenizer trusts the fake upstream
through `SSL_CERT_FILE` (Go's system pool), which is why the upstream CA needs
no code change.

## Limits of phase 1

- HTTP/1.1 only. HTTP/2 is not offered (ALPN is `http/1.1`); websockets and
  other upgrades are not relayed. Clients that need h2 fall back to 1.1.
- IPv6 literal upstreams need the patched tokenizer built by this flake (see
  "IPv4 and IPv6").
- Tokenizer is dialed per request; there is no connection reuse.
- A secret's JSON is whatever tokenizer accepts. Processors that return
  sealed tokens in responses (OAuth) are not handled by the broker.

## Next steps

- OAuth flows and refresh caching (token endpoints, refresh tokens, sealing
  the refreshed access token back into the store).
- A Datum Secret store backend, and writing sealed secrets through it.
- yolo CLI integration: create each sandbox's key and policy entry, set
  `HTTPS_PROXY` and the CA trust in the sandbox.
- Image changes: ship `yolo-broker-proxy` and the CA certificate.
- Serving the CA certificate to the proxy over the iroh connection.
- HTTP/2, and transparent (non-proxy) interception.
- Per-sandbox request rate limits; metrics beyond the audit log.
- Name constraints on the CA, binding the proxy's identity to more than a key
  file.
