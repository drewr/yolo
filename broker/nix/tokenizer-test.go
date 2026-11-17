// Test-only entry point for superfly/tokenizer: the stock `serve` command
// refuses to dial loopback upstreams, so the integration tests (whose fake
// upstream is on 127.0.0.1) run this instead. It only wires up tokenizer's
// public API; the library is unmodified. Never deploy this binary.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"

	"github.com/superfly/tokenizer"
)

func main() {
	l, err := net.Listen("tcp", os.Getenv("LISTEN_ADDRESS"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	tkz := tokenizer.NewTokenizer(os.Getenv("OPEN_KEY"), tokenizer.AllowPrivateUpstreams())
	fmt.Fprintf(os.Stderr, "listening address=%s seal_key=%s\n", l.Addr(), tkz.SealKey())
	if err := http.Serve(l, tkz); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
