// wsproxy - single-binary PoC server for the FreeRDP WASM client.
//   * serves the static WASM site (with COOP/COEP required by SharedArrayBuffer)
//   * proxies /ws (WebSocket) <-> RDP TCP, websockify "binary" compatible
// Pure Go, CGO_ENABLED=0, no nginx, no python websockify.
//
// Usage:
//   wsproxy -listen 0.0.0.0:8180 -target 192.168.1.10:3389 -site ./dist/site
package main

import (
	"embed"
	"errors"
	"flag"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// embeddedSite contains a snapshot of the WASM client so the proxy binary can
// run truly standalone (single file, no dist/site directory required).
// A disk -site directory, when present, takes precedence for hot reloads.
//
//go:embed all:site
var embeddedSite embed.FS

var (
	listen   = flag.String("listen", "0.0.0.0:8180", "HTTP/WS listen address")
	target   = flag.String("target", "", "RDP TCP target host:port (required)")
	siteDir  = flag.String("site", "", "static WASM site directory (default ./dist/site)")
	noStatic = flag.Bool("no-static", false, "disable static file serving (proxy only)")
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  32 * 1024,
	WriteBufferSize: 32 * 1024,
	Subprotocols:    []string{"binary"}, // websockify subprotocol expected by the upstream WASM client
	CheckOrigin:     func(r *http.Request) bool { return true }, // PoC behind auth proxy only
}

func main() {
	flag.Parse()
	if *target == "" {
		log.Fatal("-target is required (e.g. 192.168.1.10:3389)")
	}
	if *siteDir == "" {
		exe, _ := os.Executable()
		*siteDir = filepath.Join(filepath.Dir(exe), "dist", "site")
	}
	siteFromDisk := false
	if st, err := os.Stat(*siteDir); err == nil && st.IsDir() {
		siteFromDisk = true
	} else {
		log.Printf("[wsproxy] no disk site at %q; using embedded WASM client", *siteDir)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/ws", handleWS)

	var siteHandler http.Handler
	if siteFromDisk {
		siteHandler = http.FileServer(http.Dir(*siteDir))
	} else {
		sub, err := fs.Sub(embeddedSite, "site")
		if err != nil {
			log.Fatalf("[wsproxy] embedded site broken: %v", err)
		}
		siteHandler = http.FileServer(http.FS(sub))
	}

	if !*noStatic {
		// Double safety: if a client (e.g. a WASM client whose fake DNS table is
		// broken) connects to the root path with an Upgrade: websocket header,
		// route it to handleWS as well. Ordinary requests still serve the site.
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" && strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
			strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
				handleWS(w, r)
				return
			}
			withIsolationHeaders(siteHandler).ServeHTTP(w, r)
		})
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	source := "embedded"
	if siteFromDisk {
		source = *siteDir
	}
	log.Printf("[wsproxy] listening %s | ws -> %s | site <- %s", *listen, *target, source)
	log.Fatal(srv.ListenAndServe())
}

// withIsolationHeaders sets COOP/COEP required by WASM threads/SharedArrayBuffer.
func withIsolationHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
		// Make sure .wasm is served with the right MIME type.
		if strings.HasSuffix(r.URL.Path, ".wasm") {
			w.Header().Set("Content-Type", "application/wasm")
		}
		next.ServeHTTP(w, r)
	})
}

func handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[wsproxy] upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	tcp, err := net.DialTimeout("tcp", *target, 10*time.Second)
	if err != nil {
		log.Printf("[wsproxy] dial %s failed: %v", *target, err)
		_ = conn.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "dial failed"))
		return
	}
	defer tcp.Close()

	log.Printf("[wsproxy] connected %s -> %s (subprotocol=%q)", r.RemoteAddr, *target, conn.Subprotocol())

	// Closing either side must unblock the other copy loop; otherwise wg.Wait()
	// hangs forever when one direction reaches EOF.
	var closeOnce sync.Once
	closeBoth := func() {
		closeOnce.Do(func() {
			_ = conn.Close()
			_ = tcp.Close()
		})
	}

	var wg sync.WaitGroup
	wg.Add(2)

	go func() { // TCP -> WS
		defer wg.Done()
		defer closeBoth()
		buf := make([]byte, 32*1024)
		for {
			n, err := tcp.Read(buf)
			if n > 0 {
				if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					log.Printf("[wsproxy] ws write: %v", werr)
					return
				}
			}
			if err != nil {
				if err != io.EOF && !errors.Is(err, net.ErrClosed) {
					log.Printf("[wsproxy] tcp read: %v", err)
				}
				return
			}
		}
	}()

	go func() { // WS -> TCP
		defer wg.Done()
		defer closeBoth()
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) &&
					!errors.Is(err, net.ErrClosed) {
					log.Printf("[wsproxy] ws read: %v", err)
				}
				return
			}
			if mt != websocket.BinaryMessage {
				continue // RDP data is always binary
			}
			if _, err := tcp.Write(data); err != nil {
				if !errors.Is(err, net.ErrClosed) {
					log.Printf("[wsproxy] tcp write: %v", err)
				}
				return
			}
		}
	}()

	wg.Wait()
}
