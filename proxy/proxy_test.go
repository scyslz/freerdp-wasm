package main

import (
	"bytes"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// echoTCP starts a TCP echo server on a random loopback port.
func echoTCP(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen echo: %v", err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				_, _ = io.Copy(c, c) // echo every byte back unchanged
			}()
		}
	}()
	t.Cleanup(func() { _ = ln.Close() })
	return ln.Addr().String()
}

// TestBinaryRoundTrip verifies the WS "binary" subprotocol forwards raw bytes
// without corruption, including payloads larger than the 32 KiB copy buffer.
func TestBinaryRoundTrip(t *testing.T) {
	old := *target
	*target = echoTCP(t)
	t.Cleanup(func() { *target = old })

	srv := httptest.NewServer(http.HandlerFunc(handleWS))
	defer srv.Close()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	d := websocket.Dialer{Subprotocols: []string{"binary"}, HandshakeTimeout: 3 * time.Second}
	conn, resp, err := d.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v (resp=%v)", err, resp)
	}
	defer conn.Close()

	if got := conn.Subprotocol(); got != "binary" {
		t.Fatalf("subprotocol = %q, want \"binary\"", got)
	}

	big := make([]byte, 96*1024) // > 32 KiB: spans several read/write chunks
	_, _ = rand.New(rand.NewSource(1)).Read(big)
	cases := [][]byte{
		[]byte("hello"),
		{0x00, 0xff, 0x7f, 0x80, 0x0a, 0x0d},
		bytes.Repeat([]byte{0xa5}, 32*1024), // exactly one buffer
		big,
	}
	for i, payload := range cases {
		if err := conn.WriteMessage(websocket.BinaryMessage, payload); err != nil {
			t.Fatalf("case %d write: %v", i, err)
		}
		// The proxy may split a large TCP read into several WS frames. RDP over
		// WS is a byte stream, so accumulate frames until the echo is complete.
		got := make([]byte, 0, len(payload))
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		for len(got) < len(payload) {
			mt, chunk, err := conn.ReadMessage()
			if err != nil {
				t.Fatalf("case %d read: %v", i, err)
			}
			if mt != websocket.BinaryMessage {
				t.Fatalf("case %d type = %d, want binary", i, mt)
			}
			got = append(got, chunk...)
		}
		if !bytes.Equal(got[:len(payload)], payload) {
			t.Fatalf("case %d mismatch: got %d bytes, want %d", i, len(got), len(payload))
		}
		t.Logf("case %d: %d bytes OK", i, len(payload))
	}
}

// TestNonBinaryIgnored verifies text frames are dropped (RDP data is binary only).
func TestNonBinaryIgnored(t *testing.T) {
	old := *target
	*target = echoTCP(t)
	t.Cleanup(func() { *target = old })

	srv := httptest.NewServer(http.HandlerFunc(handleWS))
	defer srv.Close()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	if err := conn.WriteMessage(websocket.TextMessage, []byte("should be dropped")); err != nil {
		t.Fatalf("write text: %v", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("real-data")); err != nil {
		t.Fatalf("write binary: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, got, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != "real-data" {
		t.Fatalf("got %q, want \"real-data\"", got)
	}
}
