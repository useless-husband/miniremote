package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Display struct {
	Index   int
	X, Y    int
	W, H    int
	Primary bool
	Name    string
}

type Server struct {
	cfg      Config
	dir      string
	htmlPath string
	sessions *Sessions
	files    *Files
	enc      EncoderInfo

	mu            sync.Mutex
	clients       map[*Client]struct{}
	cap           *Capture
	activeCodec   string
	displays      []Display
	curDisplay    int
	presets       [][2]int
	fps           int
	width, height int
	bitrate       int // 上限
	curBitrate    int // 自動調整後實際用的
	auto          bool
	jpegQ         float64
	userChoseSize bool
	idleTimer     *time.Timer
	restartTimer  *time.Timer
	stableSeconds int
	dropSeconds   int

	sentFrames, sentBytes, captured, drops int
	encDrops                               int
	startedAt                              time.Time
}

func newServer(cfg Config, dir string) *Server {
	s := &Server{
		cfg: cfg, dir: dir, clients: map[*Client]struct{}{},
		sessions: newSessions(filepath.Join(dir, "sessions.json"), cfg.SessionDays),
		files:    newFiles(cfg.FileRoots),
		fps:      clampInt(cfg.FPS, 1, 120), bitrate: clampInt(cfg.BitrateKbps, 200, 100000),
		auto: cfg.AutoBitrate, jpegQ: clampF(cfg.JpegQuality, 0.1, 1.0), startedAt: time.Now(),
	}
	s.curBitrate = s.bitrate
	for _, p := range []string{filepath.Join(dir, "index.html"), filepath.Join(dir, "Client", "index.html")} {
		if _, err := os.Stat(p); err == nil {
			s.htmlPath = p
			break
		}
	}
	if s.htmlPath == "" {
		logf("警告:找不到 index.html,網頁端無法載入")
	}
	return s
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
func clampF(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// MARK: 啟動

func (s *Server) run() error {
	s.enc = probeEncoders(s.cfg.FFmpeg, s.cfg.Encoder, s.cfg.Capture)
	logf("ffmpeg:%s;H.264 編碼器:%s;HEVC 編碼器:%s;擷取方式:%s", s.cfg.FFmpeg, orNone(s.enc.H264), orNone(s.enc.HEVC), s.enc.Capture)
	if s.enc.H264 == "" && s.enc.HEVC == "" {
		logf("⚠️ 找不到任何可用的影像編碼器,只能用 JPEG 模式;請確認 ffmpeg.exe 存在且可執行")
	}
	s.displays = listDisplays()
	idx := 0
	for i, d := range s.displays {
		if d.Primary {
			idx = i
		}
	}
	s.selectDisplay(idx)
	logf("檔案根目錄 %v;%s", s.files.roots, map[bool]string{true: "允許區網連線", false: "只接受 Tailscale/本機連線"}[s.cfg.AllowLAN])

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", s.cfg.Port))
	if err != nil {
		return err
	}
	fl := &filteredListener{Listener: ln, allowLAN: s.cfg.AllowLAN}
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleHTTP)
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 15 * time.Second}
	go s.ticker()
	logf("伺服器已啟動,port %d", s.cfg.Port)
	return srv.Serve(fl)
}

func orNone(s string) string {
	if s == "" {
		return "無"
	}
	return s
}

type filteredListener struct {
	net.Listener
	allowLAN bool
}

func hostOf(addr net.Addr) string {
	h, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	if i := strings.Index(h, "%"); i >= 0 {
		h = h[:i]
	}
	return h
}

func isLoopback(h string) bool {
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// Tailscale 位址:100.64.0.0/10 或 fd7a:115c:a1e0::/48
func isTailscale(h string) bool {
	ip := net.ParseIP(h)
	if ip == nil {
		return false
	}
	if v4 := ip.To4(); v4 != nil {
		return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
	}
	return strings.HasPrefix(strings.ToLower(ip.String()), "fd7a:115c:a1e0:")
}

func (l *filteredListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		h := hostOf(c.RemoteAddr())
		if isLoopback(h) || isTailscale(h) || l.allowLAN {
			return c, nil
		}
		logf("拒絕非 Tailscale 的連線:%s", h)
		c.Close()
	}
}

func (s *Server) selectDisplay(idx int) {
	if len(s.displays) == 0 {
		s.displays = []Display{{Index: 0, W: 1920, H: 1080, Primary: true, Name: "Display"}}
	}
	if idx < 0 || idx >= len(s.displays) {
		idx = 0
	}
	d := s.displays[idx]
	s.curDisplay = idx
	s.presets = makePresets(d.W, d.H)
	if !s.userChoseSize || s.width == 0 {
		s.width, s.height = d.W&^1, d.H&^1
		if s.cfg.MaxHeight > 0 {
			for _, p := range s.presets {
				if p[1] <= s.cfg.MaxHeight {
					s.width, s.height = p[0], p[1]
					break
				}
			}
		}
	}
}

func makePresets(pw, ph int) [][2]int {
	aspect := float64(pw) / float64(max(1, ph))
	seen := map[int]bool{}
	var hs []int
	for _, h := range []int{ph, 1440, 1080, 900, 720, 540} {
		if h <= ph && h >= 360 && !seen[h] {
			seen[h] = true
			hs = append(hs, h)
		}
	}
	if len(hs) == 0 {
		hs = []int{ph}
	}
	out := make([][2]int, 0, len(hs))
	for _, h := range hs {
		w := int(float64(h)*aspect/2+0.5) * 2
		out = append(out, [2]int{w, h &^ 1})
	}
	return out
}

// MARK: HTTP

var htmlHeaders = map[string]string{
	"Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self' ws: wss:; frame-ancestors 'none'",
	"X-Frame-Options":         "DENY",
	"Referrer-Policy":         "no-referrer",
	"X-Content-Type-Options":  "nosniff",
	"Cache-Control":           "no-store",
}

func (s *Server) tailscaleAllowed(login string) bool {
	if len(s.cfg.AllowedTailscaleLogins) == 0 || login == "" {
		return true
	}
	for _, a := range s.cfg.AllowedTailscaleLogins {
		if strings.EqualFold(a, login) {
			return true
		}
	}
	return false
}

func (s *Server) httpAuthorized(r *http.Request, login string) bool {
	if !s.tailscaleAllowed(login) {
		return false
	}
	token := r.URL.Query().Get("token")
	if c, err := r.Cookie("mr_session"); err == nil && c.Value != "" {
		token = c.Value
	}
	return s.sessions.validate(token)
}

func (s *Server) handleHTTP(w http.ResponseWriter, r *http.Request) {
	remote := hostOf(&addrString{r.RemoteAddr})
	tsLogin := ""
	if isLoopback(remote) {
		tsLogin = r.Header.Get("Tailscale-User-Login")
	}
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		s.upgrade(w, r, remote, tsLogin)
		return
	}
	switch {
	case r.Method == "GET" && (r.URL.Path == "/" || r.URL.Path == "/index.html"):
		data, err := os.ReadFile(s.htmlPath)
		if err != nil {
			http.Error(w, "找不到 index.html", 500)
			return
		}
		for k, v := range htmlHeaders {
			w.Header().Set(k, v)
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(data)
	case r.Method == "GET" && r.URL.Path == "/health":
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		w.Write([]byte("ok"))
	case r.Method == "GET" && r.URL.Path == "/api/list":
		if !s.httpAuthorized(r, tsLogin) {
			http.Error(w, "unauthorized", 401)
			return
		}
		listing, ok := s.files.list(r.URL.Query().Get("path"), r.URL.Query().Get("hidden") == "1")
		if !ok {
			writeJSON(w, 404, map[string]any{"error": "無法讀取這個路徑"})
			return
		}
		writeJSON(w, 200, listing)
	case r.Method == "GET" && r.URL.Path == "/api/download":
		if !s.httpAuthorized(r, tsLogin) {
			http.Error(w, "unauthorized", 401)
			return
		}
		p, ok := s.files.resolve(r.URL.Query().Get("path"))
		if !ok {
			http.Error(w, "路徑不允許", 403)
			return
		}
		name := filepath.Base(p)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		if s.files.isDir(p) {
			logf("打包下載資料夾 %s → %s", p, remote)
			w.Header().Set("Content-Type", "application/zip")
			w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(name+".zip"))
			w.WriteHeader(200)
			s.files.zipDir(w, p)
			return
		}
		logf("下載 %s → %s", p, remote)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(name))
		http.ServeFile(w, r, p)
	case r.Method == "POST" && r.URL.Path == "/api/upload":
		if !s.httpAuthorized(r, tsLogin) {
			http.Error(w, "unauthorized", 401)
			return
		}
		dir, ok := s.files.resolve(r.URL.Query().Get("dir"))
		if !ok || !s.files.isDir(dir) {
			http.Error(w, "目的地不允許", 403)
			return
		}
		dest, ok := s.files.uniqueDest(dir, r.URL.Query().Get("name"))
		if !ok {
			http.Error(w, "檔名不合法", 403)
			return
		}
		logf("上傳 %s ← %s", filepath.Base(dest), remote)
		f, err := os.Create(dest)
		if err != nil {
			http.Error(w, "無法寫入", 500)
			return
		}
		if _, err := io.Copy(f, r.Body); err != nil {
			f.Close()
			os.Remove(dest)
			http.Error(w, "上傳中斷", 500)
			return
		}
		f.Close()
		writeJSON(w, 200, map[string]any{"ok": true, "path": dest, "name": filepath.Base(dest)})
	default:
		http.NotFound(w, r)
	}
}

type addrString struct{ s string }

func (a *addrString) Network() string { return "tcp" }
func (a *addrString) String() string  { return a.s }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) upgrade(w http.ResponseWriter, r *http.Request, remote, tsLogin string) {
	if origin := r.Header.Get("Origin"); origin != "" {
		if u, err := url.Parse(origin); err != nil || !strings.HasPrefix(strings.ToLower(r.Host), strings.ToLower(u.Hostname())) {
			http.Error(w, "forbidden origin", 403)
			return
		}
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		http.Error(w, "bad request", 400)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "no hijack", 500)
		return
	}
	conn, brw, err := hj.Hijack()
	if err != nil {
		return
	}
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	accept := base64.StdEncoding.EncodeToString(sum[:])
	brw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n")
	brw.Flush()
	conn.SetDeadline(time.Time{})
	c := newClient(s, conn, brw.Reader, remote, isLoopback(remote), isTailscale(remote), tsLogin)
	if s.enc.HEVC == "" {
		c.codec = "h264"
	}
	if s.enc.H264 == "" && s.enc.HEVC == "" {
		c.codec = "jpeg"
	}
	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
	go c.writeLoop()
	go c.readLoop()
}

func (s *Server) removeClient(c *Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.clients[c]; !ok {
		return
	}
	delete(s.clients, c)
	if c.authed {
		logf("客戶端離線 %s(丟棄 %d 幀)", c.remote, c.dropped)
		inputReleaseAll()
		s.clientsChangedLocked()
	}
}

// MARK: 訊息處理

func jstr(m map[string]any, k string) string {
	v, _ := m[k].(string)
	return v
}
func jnum(m map[string]any, k string) (float64, bool) {
	v, ok := m[k].(float64)
	return v, ok
}
func jint(m map[string]any, k string) (int, bool) {
	v, ok := m[k].(float64)
	return int(v), ok
}
func jbool(m map[string]any, k string) (bool, bool) {
	v, ok := m[k].(bool)
	return v, ok
}

func toJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func (s *Server) handleText(c *Client, text string) {
	var obj map[string]any
	if err := json.Unmarshal([]byte(text), &obj); err != nil {
		return
	}
	typ := jstr(obj, "type")
	s.mu.Lock()
	defer s.mu.Unlock()
	if !c.authed {
		if typ == "auth" {
			s.handleAuthLocked(c, obj)
		}
		return
	}
	d := s.displays[s.curDisplay]
	switch typ {
	case "config":
		s.applyConfigLocked(c, obj)
	case "key":
		c.needsKey = true
	case "pause":
		on, _ := jbool(obj, "on")
		c.paused = on
		if !on {
			c.needsKey = true
		}
		s.clientsChangedLocked()
	case "mouse":
		x, _ := jnum(obj, "x")
		y, _ := jnum(obj, "y")
		btn, _ := jint(obj, "button")
		switch jstr(obj, "t") {
		case "move":
			inputMouseMove(x, y, d)
		case "down":
			inputMouseButton(btn, true, x, y, d)
		case "up":
			inputMouseButton(btn, false, x, y, d)
		}
	case "wheel":
		dx, _ := jnum(obj, "dx")
		dy, _ := jnum(obj, "dy")
		inputScroll(dx, dy)
	case "keyev":
		dn, _ := jint(obj, "d")
		mods, _ := jint(obj, "m")
		inputKey(jstr(obj, "code"), jstr(obj, "key"), dn == 1, mods, s.cfg.CmdAsCtrl)
	case "text":
		if t := jstr(obj, "text"); t != "" && len(t) <= 8000 {
			inputText(t)
		}
	case "release":
		inputReleaseAll()
	case "ping":
		c.sendText(toJSON(map[string]any{"type": "pong", "t": obj["t"]}))
	case "logout":
		if c.token != "" {
			s.sessions.revoke(c.token)
		}
		logf("登出並註銷 token:%s", c.remote)
		c.sendTextThenClose(`{"type":"logout","ok":true}`)
	}
}

func (s *Server) handleAuthLocked(c *Client, obj map[string]any) {
	if !s.tailscaleAllowed(c.tsLogin) {
		logf("拒絕:Tailscale 帳號 %s 不在允許名單", c.tsLogin)
		c.sendTextThenClose(`{"type":"auth","ok":false,"reason":"tailscale"}`)
		return
	}
	if locked := s.sessions.lockedSeconds(c.remote); locked > 0 {
		c.sendTextThenClose(toJSON(map[string]any{"type": "auth", "ok": false, "reason": "locked", "seconds": locked}))
		return
	}
	ok, viaToken := false, false
	if t := jstr(obj, "token"); t != "" {
		viaToken = true
		ok = s.sessions.validate(t)
		if ok {
			c.token = t
		}
	} else if pw, has := obj["password"].(string); has {
		ok = s.cfg.Password == "" || passwordMatches(pw, s.cfg.Password)
	}
	if !ok {
		n := s.sessions.recordFailure(c.remote)
		what := "密碼錯誤"
		if viaToken {
			what = "token 無效"
		}
		extra := ""
		if n >= maxFailures {
			extra = fmt.Sprintf(",已鎖定 %d 分鐘", lockMinutes)
		}
		logf("%s(第 %d 次)來自 %s%s", what, n, c.remote, extra)
		reason := "password"
		if viaToken {
			reason = "token"
		}
		delay := time.Duration(min(5000, n*500)) * time.Millisecond
		time.AfterFunc(delay, func() { c.sendTextThenClose(toJSON(map[string]any{"type": "auth", "ok": false, "reason": reason})) })
		return
	}
	s.sessions.clearFailures(c.remote)
	c.authed = true
	c.needsKey = true
	if want := jstr(obj, "codec"); want != "" {
		c.codec = s.normalizeCodec(want)
	} else {
		c.codec = s.normalizeCodec(c.codec)
	}
	reply := map[string]any{"type": "auth", "ok": true}
	if !viaToken {
		label := fmt.Sprintf("%s %s %s", c.remote, c.tsLogin, time.Now().Format("2006-01-02 15:04"))
		c.token = s.sessions.issue(label)
		reply["token"] = c.token
	}
	c.sendText(toJSON(reply))
	how := "密碼登入"
	if viaToken {
		how = "token 登入"
	}
	ts := ""
	if c.tsLogin != "" {
		ts = "(Tailscale 帳號 " + c.tsLogin + ")"
	}
	logf("客戶端上線 %s%s,%s,編碼 %s", c.remote, ts, how, c.codec)
	s.sendHelloLocked(c)
	s.clientsChangedLocked()
}

func (s *Server) normalizeCodec(want string) string {
	switch want {
	case "hevc":
		if s.enc.HEVC != "" {
			return "hevc"
		}
		fallthrough
	case "h264":
		if s.enc.H264 != "" {
			return "h264"
		}
		return "jpeg"
	default:
		return "jpeg"
	}
}

func (s *Server) applyConfigLocked(c *Client, obj map[string]any) {
	restart := false
	if f, ok := jint(obj, "fps"); ok && f >= 1 && f <= 120 && f != s.fps {
		s.fps = f
		restart = true
	}
	if w, ok := jint(obj, "width"); ok {
		if h, ok2 := jint(obj, "height"); ok2 && w >= 160 && h >= 90 && w <= 8192 && h <= 8192 && (w&^1 != s.width || h&^1 != s.height) {
			s.width, s.height = w&^1, h&^1
			s.userChoseSize = true
			restart = true
		}
	}
	if b, ok := jint(obj, "bitrateKbps"); ok && b >= 200 && b <= 100000 {
		if b != s.bitrate {
			s.bitrate, s.curBitrate = b, b
			s.stableSeconds = 0
			restart = true
		}
	}
	if a, ok := jbool(obj, "autoBitrate"); ok {
		s.auto = a
	}
	if v, ok := jbool(obj, "cmdAsCtrl"); ok {
		s.cfg.CmdAsCtrl = v
	}
	if q, ok := jnum(obj, "quality"); ok && q >= 0.1 && q <= 1.0 && q != s.jpegQ {
		s.jpegQ = q
		if s.activeCodec == "jpeg" {
			restart = true
		}
	}
	if codec := jstr(obj, "codec"); codec != "" {
		nc := s.normalizeCodec(codec)
		if nc != c.codec {
			c.codec = nc
			c.needsKey = true
		}
	}
	if di, ok := jint(obj, "display"); ok && di != s.curDisplay && di >= 0 && di < len(s.displays) {
		logf("切換顯示器 → %d(%s)", di, s.displays[di].Name)
		s.userChoseSize = false
		s.selectDisplay(di)
		restart = true
	}
	if restart {
		logf("設定變更:%d×%d @ %d fps,上限 %d kbps%s", s.width, s.height, s.fps, s.bitrate, map[bool]string{true: "(自動)", false: ""}[s.auto])
	}
	s.ensureCaptureLocked(restart)
	s.broadcastConfigLocked()
}

func (s *Server) currentConfig(c *Client) map[string]any {
	return map[string]any{
		"type": "config", "fps": s.fps, "width": s.width, "height": s.height, "bitrateKbps": s.bitrate,
		"autoBitrate": s.auto, "quality": s.jpegQ, "display": s.curDisplay, "codec": c.codec,
	}
}

func (s *Server) broadcastConfigLocked() {
	for c := range s.clients {
		if c.authed {
			c.sendText(toJSON(s.currentConfig(c)))
		}
	}
}

func (s *Server) sendHelloLocked(c *Client) {
	disp := []map[string]any{}
	for i, d := range s.displays {
		name := fmt.Sprintf("%d×%d", d.W, d.H)
		if d.Primary {
			name += "(主要)"
		}
		disp = append(disp, map[string]any{"id": i, "name": name, "width": d.W, "height": d.H})
	}
	codecs := []string{}
	if s.enc.HEVC != "" {
		codecs = append(codecs, "hevc")
	}
	if s.enc.H264 != "" {
		codecs = append(codecs, "h264")
	}
	codecs = append(codecs, "jpeg")
	presets := make([][]int, 0, len(s.presets))
	for _, p := range s.presets {
		presets = append(presets, []int{p[0], p[1]})
	}
	peers := s.cfg.Peers
	if peers == nil {
		peers = []Peer{}
	}
	hello := map[string]any{
		"type": "hello", "version": "2.0-win", "os": runtime.GOOS, "name": s.cfg.Name,
		"displays": disp, "presets": presets,
		"fpsOptions":     []int{5, 10, 15, 20, 24, 30, 60, 90, 120},
		"bitrateOptions": []int{1000, 2000, 3000, 4000, 6000, 8000, 12000, 16000, 24000, 30000, 40000},
		"codecs":         codecs, "files": len(s.files.roots) > 0, "testPattern": false,
		"tailscaleLogin": c.tsLogin, "peers": peers, "cmdAsCtrl": s.cfg.CmdAsCtrl,
		"encoder": map[string]string{"h264": s.enc.H264, "hevc": s.enc.HEVC, "capture": s.enc.Capture},
		"current": s.currentConfig(c),
	}
	c.sendText(toJSON(hello))
}

// MARK: 擷取管理

func (s *Server) activeClientsLocked() []*Client {
	var out []*Client
	for c := range s.clients {
		if c.authed && !c.paused {
			out = append(out, c)
		}
	}
	return out
}

func (s *Server) authedCountLocked() int {
	n := 0
	for c := range s.clients {
		if c.authed {
			n++
		}
	}
	return n
}

// 依目前的客戶端決定要用哪種編碼(一次只能跑一種);有變就重啟 ffmpeg
func (s *Server) ensureCaptureLocked(force bool) {
	active := s.activeClientsLocked()
	if len(active) == 0 {
		return
	}
	// 以最多人要的編碼為主;有人要 hevc 且可用就 hevc
	want := ""
	for _, c := range active {
		if want == "" || c.codec == "hevc" {
			want = c.codec
		}
	}
	for _, c := range active {
		if c.codec != want {
			c.codec = want
			c.needsKey = true
		}
	}
	p := CaptureParams{Codec: want, W: s.width, H: s.height, FPS: s.fps, Bitrate: s.curBitrate, Quality: s.jpegQ, Display: s.displays[s.curDisplay]}
	if s.cap != nil && !force && s.cap.p == p {
		return
	}
	if s.cap != nil {
		old := s.cap
		s.cap = nil
		go old.stop()
	}
	s.activeCodec = want
	args := buildFFmpegArgs(s.enc, p)
	cap, err := startCapture(s.cfg.FFmpeg, args, p, s.onFrame)
	if err != nil {
		logf("啟動 ffmpeg 失敗:%v(指令:%s %s)", err, s.cfg.FFmpeg, strings.Join(args, " "))
		return
	}
	s.cap = cap
	logf("開始擷取 顯示器 %d(%d×%d),輸出 %d×%d @ %d fps,%s,%d kbps", s.curDisplay, p.Display.W, p.Display.H, p.W, p.H, p.FPS, strings.ToUpper(want), p.Bitrate)
	for _, c := range active {
		c.needsKey = true
	}
}

func (s *Server) stopCaptureLocked(reason string) {
	if s.cap == nil {
		return
	}
	old := s.cap
	s.cap = nil
	go old.stop()
	logf("停止擷取:%s", reason)
}

func (s *Server) clientsChangedLocked() {
	n := s.authedCountLocked()
	if n > 0 {
		if s.idleTimer != nil {
			s.idleTimer.Stop()
			s.idleTimer = nil
		}
		setAwake(true)
		if len(s.activeClientsLocked()) > 0 {
			s.ensureCaptureLocked(false)
		} else {
			s.stopCaptureLocked("所有客戶端都暫停")
		}
		return
	}
	setAwake(false)
	if s.cfg.IdleStopSeconds > 0 {
		if s.idleTimer != nil {
			s.idleTimer.Stop()
		}
		s.idleTimer = time.AfterFunc(time.Duration(s.cfg.IdleStopSeconds)*time.Second, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.authedCountLocked() == 0 {
				s.stopCaptureLocked(fmt.Sprintf("沒有人連線 %d 秒(省電);有人連上會自動恢復", s.cfg.IdleStopSeconds))
			}
		})
	}
}

// MARK: 影像廣播

func (s *Server) onFrame(f Frame) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cap == nil || f.Codec != s.activeCodec {
		return
	}
	s.captured++
	msg := videoMessage(f)
	for _, c := range s.activeClientsLocked() {
		if c.codec != f.Codec {
			continue
		}
		s.deliverLocked(c, msg, f.Key)
	}
}

func (s *Server) deliverLocked(c *Client, msg []byte, key bool) {
	if c.needsKey && !key {
		return
	}
	congested := c.pending.Load() > 1<<20 || c.queued() > 12
	if congested && (!key || c.pending.Load() > 3<<20) {
		c.needsKey = true
		c.dropped++
		s.drops++
		return
	}
	if !c.sendBinary(msg) {
		c.needsKey = true
		c.dropped++
		s.drops++
		return
	}
	c.needsKey = false
	s.sentFrames++
	s.sentBytes += len(msg)
}

// type(1) flags(1) width(2) height(2) pts_us(8) descLen(2) [desc] payload;type 1=H.264 2=JPEG 3=HEVC
func videoMessage(f Frame) []byte {
	t := byte(2)
	switch f.Codec {
	case "h264":
		t = 1
	case "hevc":
		t = 3
	}
	out := make([]byte, 16, 16+len(f.Desc)+len(f.Data))
	out[0] = t
	if f.Key {
		out[1] = 1
	}
	binary.BigEndian.PutUint16(out[2:], uint16(f.W))
	binary.BigEndian.PutUint16(out[4:], uint16(f.H))
	binary.BigEndian.PutUint64(out[6:], f.PTS)
	binary.BigEndian.PutUint16(out[14:], uint16(len(f.Desc)))
	out = append(out, f.Desc...)
	return append(out, f.Data...)
}

// MARK: 每秒:統計、自動位元率

func (s *Server) ticker() {
	t := time.NewTicker(time.Second)
	for range t.C {
		s.mu.Lock()
		s.adjustBitrateLocked()
		if n := s.authedCountLocked(); n > 0 {
			enc := 0
			if s.cap != nil {
				enc = s.cap.encDropsAndReset()
			}
			stats := map[string]any{
				"type": "stats", "fps": s.sentFrames, "kbps": s.sentBytes * 8 / 1000, "captured": s.captured,
				"clients": len(s.activeClientsLocked()), "width": s.width, "height": s.height,
				"bitrateNow": s.curBitrate, "bitrateMax": s.bitrate, "auto": s.auto, "drops": s.drops, "encDrops": enc,
			}
			text := toJSON(stats)
			for c := range s.clients {
				if c.authed {
					c.sendText(text)
				}
			}
		}
		s.sentFrames, s.sentBytes, s.captured, s.drops = 0, 0, 0, 0
		s.mu.Unlock()
	}
}

// ffmpeg 不能線上改位元率,所以調整時要重啟;為了不要一直重啟,降得快、升得慢
func (s *Server) adjustBitrateLocked() {
	if !s.auto || s.activeCodec == "jpeg" || s.cap == nil {
		if s.curBitrate != s.bitrate {
			s.curBitrate = s.bitrate
		}
		return
	}
	if s.drops > 0 {
		s.dropSeconds++
		s.stableSeconds = 0
	} else {
		s.dropSeconds = 0
		s.stableSeconds++
	}
	target := s.curBitrate
	if s.dropSeconds >= 2 {
		target = max(500, int(float64(s.curBitrate)*0.6))
		s.dropSeconds = 0
	} else if s.stableSeconds >= 20 && s.curBitrate < s.bitrate {
		target = min(s.bitrate, max(s.curBitrate+1000, int(float64(s.curBitrate)*1.5)))
		s.stableSeconds = 0
	}
	if target != s.curBitrate {
		s.curBitrate = target
		logf("自動位元率 → %d kbps", target)
		s.ensureCaptureLocked(true)
	}
}

// 用在測試:回報目前狀態
func (s *Server) uptime() string { return strconv.Itoa(int(time.Since(s.startedAt).Seconds())) + "s" }

var _ = bufio.NewReader
