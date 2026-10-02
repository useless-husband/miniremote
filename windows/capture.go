package main

import (
	"bufio"
	"bytes"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type CaptureParams struct {
	Codec   string // hevc | h264 | jpeg
	W, H    int
	FPS     int
	Bitrate int
	Quality float64
	Display Display
}

type Frame struct {
	Codec string
	Key   bool
	Desc  []byte // avcC / hvcC(關鍵幀才有)
	Data  []byte // 4-byte 長度前綴的 NAL 串,或整張 JPEG
	PTS   uint64 // 微秒
	W, H  int
}

type EncoderInfo struct {
	H264    string // ffmpeg 編碼器名稱,空 = 不可用
	HEVC    string
	Capture string
}

// 一個 ffmpeg 行程:擷取螢幕 + 編碼,從 stdout 讀 Annex-B(或 JPEG 串流)切成幀
type Capture struct {
	p       CaptureParams
	cmd     *exec.Cmd
	onFrame func(Frame)
	start   time.Time

	mu          sync.Mutex
	stopped     bool
	buf         []byte
	desc        []byte // avcC / hvcC(從 moov 取得)
	sampleSizes []int
	ready       []Frame
	encDrops    int
	stderrTail  []string
}

func startCapture(ffmpeg string, args []string, p CaptureParams, onFrame func(Frame)) (*Capture, error) {
	cmd := exec.Command(ffmpeg, args...)
	hideWindow(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &Capture{p: p, cmd: cmd, onFrame: onFrame, start: time.Now()}
	go c.readStderr(stderr)
	go c.readLoop(stdout)
	return c, nil
}

func (c *Capture) stop() {
	c.mu.Lock()
	c.stopped = true
	c.mu.Unlock()
	if c.cmd.Process != nil {
		c.cmd.Process.Kill()
	}
	c.cmd.Wait()
}

func (c *Capture) encDropsAndReset() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := c.encDrops
	c.encDrops = 0
	return n
}

func (c *Capture) readStderr(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		c.mu.Lock()
		c.stderrTail = append(c.stderrTail, line)
		if len(c.stderrTail) > 20 {
			c.stderrTail = c.stderrTail[1:]
		}
		c.mu.Unlock()
		if strings.Contains(line, "rror") || strings.Contains(line, "nvalid") || strings.Contains(line, "not ") {
			logf("ffmpeg:%s", line)
		}
	}
}

func (c *Capture) readLoop(r io.Reader) {
	buf := make([]byte, 512*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			var ready []Frame
			if c.p.Codec == "jpeg" {
				ready = c.feedJPEG(buf[:n])
			} else {
				ready = c.feedMP4(buf[:n])
			}
			c.emit(ready)
		}
		if err != nil {
			c.mu.Lock()
			stopped := c.stopped
			tail := strings.Join(c.stderrTail, " | ")
			c.mu.Unlock()
			if !stopped {
				logf("ffmpeg 結束(%v)。最後訊息:%s", err, tail)
			}
			return
		}
	}
}

func (c *Capture) emit(frames []Frame) {
	for _, f := range frames {
		if c.stopped {
			return
		}
		c.onFrame(f)
	}
}

// MARK: JPEG 串流

func (c *Capture) feedJPEG(d []byte) []Frame {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.buf = append(c.buf, d...)
	var out []Frame
	for {
		i := bytes.Index(c.buf, []byte{0xFF, 0xD8})
		if i < 0 {
			c.buf = c.buf[:0]
			return out
		}
		j := bytes.Index(c.buf[i+2:], []byte{0xFF, 0xD9})
		if j < 0 {
			if i > 0 {
				c.buf = append(c.buf[:0], c.buf[i:]...)
			}
			return out
		}
		end := i + 2 + j + 2
		jpg := make([]byte, end-i)
		copy(jpg, c.buf[i:end])
		out = append(out, Frame{Codec: "jpeg", Key: true, Data: jpg, PTS: c.pts(), W: c.p.W, H: c.p.H})
		c.buf = append(c.buf[:0], c.buf[end:]...)
	}
}

func (c *Capture) pts() uint64 { return uint64(time.Since(c.start).Microseconds()) }

// MARK: fragmented MP4(frag_every_frame)→ 每個 mdat 就是一幀,邊界精確、沒有多一幀的延遲

func be32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

func (c *Capture) feedMP4(d []byte) []Frame {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.buf = append(c.buf, d...)
	for {
		if len(c.buf) < 8 {
			break
		}
		size := int(be32(c.buf))
		hdr := 8
		if size == 1 {
			if len(c.buf) < 16 {
				break
			}
			size = int(be32(c.buf[12:])) | int(be32(c.buf[8:]))<<32
			hdr = 16
		}
		if size < hdr || size > 64<<20 {
			logf("mp4 解析錯誤:box 大小 %d,重新同步", size)
			c.buf = c.buf[:0]
			break
		}
		if len(c.buf) < size {
			break
		}
		typ := string(c.buf[4:8])
		payload := c.buf[hdr:size]
		switch typ {
		case "moov":
			if desc := findDecoderConfig(payload); desc != nil {
				c.desc = desc
			}
		case "moof":
			c.sampleSizes = parseTrunSizes(payload)
		case "mdat":
			c.emitSamples(payload)
		}
		c.buf = append(c.buf[:0], c.buf[size:]...)
	}
	out := c.ready
	c.ready = nil
	return out
}

// 在 moov 裡找 avcC / hvcC(box 內容就是 WebCodecs 要的 description)
func findDecoderConfig(b []byte) []byte {
	containers := map[string]bool{"trak": true, "mdia": true, "minf": true, "stbl": true}
	var walk func(b []byte) []byte
	walk = func(b []byte) []byte {
		for len(b) >= 8 {
			size := int(be32(b))
			if size < 8 || size > len(b) {
				return nil
			}
			typ := string(b[4:8])
			body := b[8:size]
			switch {
			case containers[typ]:
				if r := walk(body); r != nil {
					return r
				}
			case typ == "stsd":
				if len(body) >= 8 {
					if r := walk(body[8:]); r != nil {
						return r
					}
				}
			case typ == "avc1" || typ == "avc3" || typ == "hvc1" || typ == "hev1":
				if len(body) >= 78 {
					if r := walk(body[78:]); r != nil {
						return r
					}
				}
			case typ == "avcC" || typ == "hvcC":
				out := make([]byte, len(body))
				copy(out, body)
				return out
			}
			b = b[size:]
		}
		return nil
	}
	return walk(b)
}

// moof → traf → trun 的 sample 大小(通常一個 fragment 只有一個 sample)
func parseTrunSizes(b []byte) []int {
	var sizes []int
	var walk func(b []byte)
	walk = func(b []byte) {
		for len(b) >= 8 {
			size := int(be32(b))
			if size < 8 || size > len(b) {
				return
			}
			typ := string(b[4:8])
			body := b[8:size]
			switch typ {
			case "traf":
				walk(body)
			case "trun":
				if len(body) < 8 {
					return
				}
				flags := be32(body) & 0xFFFFFF
				count := int(be32(body[4:]))
				pos := 8
				if flags&0x1 != 0 {
					pos += 4
				}
				if flags&0x4 != 0 {
					pos += 4
				}
				for i := 0; i < count && pos+4 <= len(body); i++ {
					if flags&0x100 != 0 {
						pos += 4
					}
					if flags&0x200 != 0 {
						if pos+4 > len(body) {
							return
						}
						sizes = append(sizes, int(be32(body[pos:])))
						pos += 4
					}
					if flags&0x400 != 0 {
						pos += 4
					}
					if flags&0x800 != 0 {
						pos += 4
					}
				}
			}
			b = b[size:]
		}
	}
	walk(b)
	return sizes
}

func (c *Capture) emitSamples(mdat []byte) {
	sizes := c.sampleSizes
	c.sampleSizes = nil
	if len(sizes) == 0 {
		sizes = []int{len(mdat)}
	}
	off := 0
	for _, sz := range sizes {
		if sz <= 0 || off+sz > len(mdat) {
			break
		}
		sample := make([]byte, sz)
		copy(sample, mdat[off:off+sz])
		off += sz
		key := c.isKeyframe(sample)
		var desc []byte
		if key {
			if c.desc == nil {
				c.encDrops++
				continue
			}
			desc = c.desc
		}
		c.ready = append(c.ready, Frame{Codec: c.p.Codec, Key: key, Desc: desc, Data: sample, PTS: c.pts(), W: c.p.W, H: c.p.H})
	}
}

// 掃過 4-byte 長度前綴的 NAL,看有沒有 IDR / IRAP
func (c *Capture) isKeyframe(sample []byte) bool {
	i := 0
	for i+5 <= len(sample) {
		n := int(be32(sample[i:]))
		if n <= 0 || i+4+n > len(sample) {
			return false
		}
		h := sample[i+4]
		if c.p.Codec == "h264" {
			if h&0x1F == 5 {
				return true
			}
		} else {
			t := (h >> 1) & 0x3F
			if t >= 16 && t <= 21 {
				return true
			}
		}
		i += 4 + n
	}
	return false
}
