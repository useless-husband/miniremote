package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// 一個已升級成 WebSocket 的客戶端
type Client struct {
	s         *Server
	conn      net.Conn
	br        *bufio.Reader
	remote    string
	loopback  bool
	tailscale bool
	tsLogin   string

	sendCh  chan []byte
	pending atomic.Int64 // 已排隊還沒寫出去的位元組數
	done    chan struct{}
	once    sync.Once
	closed  atomic.Bool

	// 以下由 Server.mu 保護
	authed      bool
	paused      bool
	codec       string
	needsKey    bool
	token       string
	dropped     int
	lastKeyWait time.Time
}

func newClient(s *Server, conn net.Conn, br *bufio.Reader, remote string, loopback, tailscale bool, tsLogin string) *Client {
	return &Client{
		s: s, conn: conn, br: br, remote: remote, loopback: loopback, tailscale: tailscale, tsLogin: tsLogin,
		sendCh: make(chan []byte, 64), done: make(chan struct{}), codec: "hevc", needsKey: true,
	}
}

func wsFrame(opcode byte, payload []byte) []byte {
	n := len(payload)
	var hdr []byte
	switch {
	case n < 126:
		hdr = []byte{0x80 | opcode, byte(n)}
	case n < 65536:
		hdr = []byte{0x80 | opcode, 126, byte(n >> 8), byte(n)}
	default:
		hdr = make([]byte, 10)
		hdr[0], hdr[1] = 0x80|opcode, 127
		binary.BigEndian.PutUint64(hdr[2:], uint64(n))
	}
	out := make([]byte, 0, len(hdr)+n)
	out = append(out, hdr...)
	return append(out, payload...)
}

// 非阻塞排隊;佇列滿就回 false(呼叫端會把它當成塞住並丟幀)
func (c *Client) enqueue(opcode byte, payload []byte) bool {
	if c.closed.Load() {
		return false
	}
	f := wsFrame(opcode, payload)
	select {
	case c.sendCh <- f:
		c.pending.Add(int64(len(f)))
		return true
	default:
		return false
	}
}

func (c *Client) sendText(s string)        { c.enqueue(1, []byte(s)) }
func (c *Client) sendBinary(b []byte) bool { return c.enqueue(2, b) }

// 送出最後一則訊息後關閉(確保對方收得到)
func (c *Client) sendTextThenClose(s string) {
	c.enqueue(1, []byte(s))
	go func() {
		deadline := time.Now().Add(2 * time.Second)
		for c.pending.Load() > 0 && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		c.close()
	}()
}

func (c *Client) queued() int { return len(c.sendCh) }

func (c *Client) writeLoop() {
	for {
		select {
		case <-c.done:
			return
		case f := <-c.sendCh:
			c.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			_, err := c.conn.Write(f)
			c.pending.Add(-int64(len(f)))
			if err != nil {
				c.close()
				return
			}
		}
	}
}

func (c *Client) readLoop() {
	defer c.close()
	var frag []byte
	var fragOp byte
	for {
		c.conn.SetReadDeadline(time.Now().Add(120 * time.Second))
		h := make([]byte, 2)
		if _, err := io.ReadFull(c.br, h); err != nil {
			return
		}
		fin := h[0]&0x80 != 0
		op := h[0] & 0x0F
		masked := h[1]&0x80 != 0
		n := int(h[1] & 0x7F)
		switch n {
		case 126:
			b := make([]byte, 2)
			if _, err := io.ReadFull(c.br, b); err != nil {
				return
			}
			n = int(binary.BigEndian.Uint16(b))
		case 127:
			b := make([]byte, 8)
			if _, err := io.ReadFull(c.br, b); err != nil {
				return
			}
			v := binary.BigEndian.Uint64(b)
			if v > 8_000_000 {
				return
			}
			n = int(v)
		}
		var mask [4]byte
		if masked {
			if _, err := io.ReadFull(c.br, mask[:]); err != nil {
				return
			}
		}
		payload := make([]byte, n)
		if _, err := io.ReadFull(c.br, payload); err != nil {
			return
		}
		if masked {
			for i := range payload {
				payload[i] ^= mask[i&3]
			}
		}
		switch op {
		case 0x0:
			frag = append(frag, payload...)
			if fin {
				if fragOp == 1 {
					c.s.handleText(c, string(frag))
				}
				frag = nil
			}
		case 0x1, 0x2:
			if fin {
				if op == 1 {
					c.s.handleText(c, string(payload))
				}
			} else {
				fragOp, frag = op, payload
			}
		case 0x8:
			c.enqueue(0x8, nil)
			return
		case 0x9:
			c.enqueue(0xA, payload)
		}
	}
}

func (c *Client) close() {
	c.once.Do(func() {
		c.closed.Store(true)
		close(c.done)
		c.conn.Close()
		c.s.removeClient(c)
	})
}

var errClosed = errors.New("closed")
