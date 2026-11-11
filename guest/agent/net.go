package main

// Network access for the sandbox.
//
// The VM has no network card. If the host attached a second virtio port
// named "labbox.net", this file runs an HTTP proxy on 127.0.0.1:3128 and
// carries each connection to the host over that port. The host decides,
// per connection, whether the destination is allowed, and does the real
// dialing and name lookups. Nothing here is a security control: code in the
// guest can talk to the port directly, and gets the same answer from the host.
//
// Frame: 4-byte big-endian length, then 1 byte kind, 4 bytes stream id, data.

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

const (
	netPortName = "labbox.net"
	proxyAddr   = "127.0.0.1:3128"
	netChunk    = 32 * 1024

	kindOpen     = 1 // guest -> host: data is "host:port"
	kindOpenOK   = 2 // host -> guest
	kindOpenFail = 3 // host -> guest: data is the reason
	kindData     = 4
	kindClose    = 5
	kindEOF      = 6 // guest -> host: client finished sending, still reading
)

type netStream struct {
	conn   net.Conn
	opened chan string   // "" for success, else the host's reason
	ready  chan struct{} // closed once the proxy has answered its client
	done   chan struct{} // closed when the stream is removed
}

type netMux struct {
	port    *os.File
	writeMu sync.Mutex
	mu      sync.Mutex
	next    uint32
	streams map[uint32]*netStream
}

var netEnabled bool

// startNet returns quietly if the host did not attach a network port.
func startNet() {
	path, ok := findPort(netPortName, 0)
	if !ok {
		return
	}
	port, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		logf("open %s: %v", path, err)
		return
	}
	if err := exec.Command("/usr/bin/busybox", "ip", "link", "set", "lo", "up").Run(); err != nil {
		logf("bring up loopback: %v", err)
		return
	}
	listener, err := net.Listen("tcp", proxyAddr)
	if err != nil {
		logf("proxy listen: %v", err)
		return
	}
	m := &netMux{port: port, streams: map[uint32]*netStream{}}
	go m.readLoop()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go m.handle(conn)
		}
	}()
	netEnabled = true
}

func proxyEnv() []string {
	if !netEnabled {
		return nil
	}
	url := "http://" + proxyAddr
	return []string{
		"HTTP_PROXY=" + url, "HTTPS_PROXY=" + url,
		"http_proxy=" + url, "https_proxy=" + url,
		"NO_PROXY=localhost,127.0.0.1", "no_proxy=localhost,127.0.0.1",
		// Node ignores the proxy variables unless told otherwise.
		"NODE_USE_ENV_PROXY=1",
	}
}

func (m *netMux) send(kind byte, id uint32, data []byte) {
	frame := make([]byte, 9+len(data))
	binary.BigEndian.PutUint32(frame, uint32(5+len(data)))
	frame[4] = kind
	binary.BigEndian.PutUint32(frame[5:], id)
	copy(frame[9:], data)
	m.writeMu.Lock()
	defer m.writeMu.Unlock()
	if _, err := m.port.Write(frame); err != nil {
		logf("net write: %v", err)
	}
}

func (m *netMux) take(id uint32) *netStream {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.streams[id]
	if s != nil {
		delete(m.streams, id)
		close(s.done)
	}
	return s
}

func (m *netMux) get(id uint32) *netStream {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.streams[id]
}

func (m *netMux) readLoop() {
	head := make([]byte, 4)
	for {
		if err := readFull(m.port, head); err != nil {
			logf("net read: %v", err)
			return
		}
		size := binary.BigEndian.Uint32(head)
		if size < 5 || size > maxFrame {
			logf("net: bad frame size %d", size)
			return
		}
		body := make([]byte, size)
		if err := readFull(m.port, body); err != nil {
			logf("net read: %v", err)
			return
		}
		kind, id, data := body[0], binary.BigEndian.Uint32(body[1:5]), body[5:]

		switch kind {
		case kindOpenOK:
			if s := m.get(id); s != nil {
				s.opened <- ""
			}
		case kindOpenFail:
			if s := m.take(id); s != nil {
				reason := string(data)
				if reason == "" {
					reason = "refused"
				}
				s.opened <- reason
			}
		case kindData:
			if s := m.get(id); s != nil {
				<-s.ready
				if _, err := s.conn.Write(data); err != nil {
					m.closeStream(id)
				}
			}
		case kindClose:
			if s := m.take(id); s != nil {
				s.conn.Close()
			}
		}
	}
}

// closeStream tells the host once, however many paths reach it.
func (m *netMux) closeStream(id uint32) {
	if s := m.take(id); s != nil {
		s.conn.Close()
		m.send(kindClose, id, nil)
	}
}

func (m *netMux) open(target string, conn net.Conn) (uint32, *netStream, string) {
	s := &netStream{conn: conn, opened: make(chan string, 1), ready: make(chan struct{}), done: make(chan struct{})}
	m.mu.Lock()
	m.next++
	id := m.next
	m.streams[id] = s
	m.mu.Unlock()

	m.send(kindOpen, id, []byte(target))
	select {
	case reason := <-s.opened:
		return id, s, reason
	case <-time.After(30 * time.Second):
		m.closeStream(id)
		return id, s, "host did not answer"
	}
}

func (m *netMux) handle(client net.Conn) {
	defer client.Close()
	reader := bufio.NewReader(client)
	req, err := http.ReadRequest(reader)
	if err != nil {
		return
	}
	refuse := func(status, why string) {
		fmt.Fprintf(client, "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nlabbox: %s\n", status, why)
	}

	target := req.Host
	if req.Method != http.MethodConnect {
		if req.URL.Host == "" {
			refuse("400 Bad Request", "this is a proxy; send an absolute URL")
			return
		}
		if req.URL.Scheme != "http" {
			// TLS has to be end to end; the client must ask for a tunnel.
			refuse("400 Bad Request", "use CONNECT for "+req.URL.Scheme+" URLs")
			return
		}
		target = req.URL.Host
		if req.URL.Port() == "" {
			target = net.JoinHostPort(req.URL.Hostname(), "80")
		}
	}

	id, stream, reason := m.open(target, client)
	if reason != "" {
		refuse("403 Forbidden", reason)
		return
	}

	if req.Method == http.MethodConnect {
		fmt.Fprint(client, "HTTP/1.1 200 Connection established\r\n\r\n")
	} else {
		// One request per connection keeps every request tied to the
		// destination the host approved.
		req.Close = true
		req.Header.Del("Proxy-Connection")
		var out bytes.Buffer
		if err := req.Write(&out); err != nil {
			m.closeStream(id)
			return
		}
		for rest := out.Bytes(); len(rest) > 0; {
			n := min(len(rest), netChunk)
			m.send(kindData, id, rest[:n])
			rest = rest[n:]
		}
	}
	close(stream.ready)

	buf := make([]byte, netChunk)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			m.send(kindData, id, buf[:n])
		}
		if errors.Is(err, io.EOF) {
			// The client is done sending but may still be reading (a
			// half-close). Pass that on and wait for the host to finish.
			m.send(kindEOF, id, nil)
			select {
			case <-stream.done:
			case <-time.After(10 * time.Minute):
			}
			break
		}
		if err != nil {
			break
		}
	}
	m.closeStream(id)
}
