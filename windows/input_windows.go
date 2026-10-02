//go:build windows

package main

import (
	"encoding/binary"
	"sync"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	procSendInput        = user32.NewProc("SendInput")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	procMapVirtualKeyW   = user32.NewProc("MapVirtualKeyW")
)

const (
	mouseMove     = 0x0001
	mouseLeftDn   = 0x0002
	mouseLeftUp   = 0x0004
	mouseRightDn  = 0x0008
	mouseRightUp  = 0x0010
	mouseMidDn    = 0x0020
	mouseMidUp    = 0x0040
	mouseWheel    = 0x0800
	mouseHWheel   = 0x1000
	mouseVirtDesk = 0x4000
	mouseAbsolute = 0x8000

	keyExtended = 0x0001
	keyUp       = 0x0002
	keyUnicode  = 0x0004
)

// INPUT 結構(64 位元):type(4) + padding(4) + union(32)
type inputRec struct {
	typ uint32
	_   uint32
	u   [32]byte
}

func sendInputs(recs []inputRec) {
	if len(recs) == 0 {
		return
	}
	procSendInput.Call(uintptr(len(recs)), uintptr(unsafe.Pointer(&recs[0])), unsafe.Sizeof(recs[0]))
}

func mouseRec(dx, dy int32, data uint32, flags uint32) inputRec {
	var r inputRec
	r.typ = 0
	binary.LittleEndian.PutUint32(r.u[0:], uint32(dx))
	binary.LittleEndian.PutUint32(r.u[4:], uint32(dy))
	binary.LittleEndian.PutUint32(r.u[8:], data)
	binary.LittleEndian.PutUint32(r.u[12:], flags)
	return r
}

func keyRec(vk, scan uint16, flags uint32) inputRec {
	var r inputRec
	r.typ = 1
	binary.LittleEndian.PutUint16(r.u[0:], vk)
	binary.LittleEndian.PutUint16(r.u[2:], scan)
	binary.LittleEndian.PutUint32(r.u[4:], flags)
	return r
}

func metric(i int) int {
	v, _, _ := procGetSystemMetrics.Call(uintptr(i))
	return int(int32(v))
}

var (
	inMu        sync.Mutex
	buttonsDown = map[int]bool{}
	keysDown    = map[uint16]bool{}
	lastAbs     [2]int32
)

func absCoords(nx, ny float64, d Display) (int32, int32) {
	if nx < 0 {
		nx = 0
	}
	if nx > 1 {
		nx = 1
	}
	if ny < 0 {
		ny = 0
	}
	if ny > 1 {
		ny = 1
	}
	px := float64(d.X) + nx*float64(d.W)
	py := float64(d.Y) + ny*float64(d.H)
	vx, vy := float64(metric(76)), float64(metric(77))
	vw, vh := float64(metric(78)), float64(metric(79))
	if vw <= 0 || vh <= 0 {
		vw, vh = float64(d.W), float64(d.H)
	}
	ax := int32((px - vx) * 65535 / vw)
	ay := int32((py - vy) * 65535 / vh)
	return ax, ay
}

func inputMouseMove(nx, ny float64, d Display) {
	ax, ay := absCoords(nx, ny, d)
	inMu.Lock()
	lastAbs = [2]int32{ax, ay}
	inMu.Unlock()
	sendInputs([]inputRec{mouseRec(ax, ay, 0, mouseMove|mouseAbsolute|mouseVirtDesk)})
}

func inputMouseButton(button int, down bool, nx, ny float64, d Display) {
	ax, ay := absCoords(nx, ny, d)
	var flag uint32
	switch button {
	case 2:
		flag = map[bool]uint32{true: mouseRightDn, false: mouseRightUp}[down]
	case 1:
		flag = map[bool]uint32{true: mouseMidDn, false: mouseMidUp}[down]
	default:
		flag = map[bool]uint32{true: mouseLeftDn, false: mouseLeftUp}[down]
	}
	inMu.Lock()
	buttonsDown[button] = down
	lastAbs = [2]int32{ax, ay}
	inMu.Unlock()
	sendInputs([]inputRec{mouseRec(ax, ay, 0, mouseMove|mouseAbsolute|mouseVirtDesk), mouseRec(0, 0, 0, flag)})
}

func inputScroll(dx, dy float64) {
	var recs []inputRec
	if dy != 0 {
		recs = append(recs, mouseRec(0, 0, uint32(int32(-dy)), mouseWheel))
	}
	if dx != 0 {
		recs = append(recs, mouseRec(0, 0, uint32(int32(dx)), mouseHWheel))
	}
	sendInputs(recs)
}

func scanOf(vk uint16) uint16 {
	v, _, _ := procMapVirtualKeyW.Call(uintptr(vk), 0)
	return uint16(v)
}

func inputKey(code, key string, down bool, mods int, cmdAsCtrl bool) {
	if cmdAsCtrl {
		switch code {
		case "MetaLeft":
			code = "ControlLeft"
		case "MetaRight":
			code = "ControlRight"
		}
	}
	k, ok := keyMap[code]
	if !ok {
		// 沒有對應鍵碼:可列印字元(含中文輸入法組好的字)直接以 Unicode 打出
		if down && (len([]rune(key)) == 1 || allNonASCII(key)) {
			inputText(key)
		}
		return
	}
	var flags uint32
	if k.ext {
		flags |= keyExtended
	}
	if !down {
		flags |= keyUp
	}
	inMu.Lock()
	if down {
		keysDown[k.code] = true
	} else {
		delete(keysDown, k.code)
	}
	inMu.Unlock()
	sendInputs([]inputRec{keyRec(k.code, scanOf(k.code), flags)})
}

func allNonASCII(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < 0x80 {
			return false
		}
	}
	return true
}

func inputText(s string) {
	units := utf16.Encode([]rune(s))
	recs := make([]inputRec, 0, len(units)*2)
	for _, u := range units {
		recs = append(recs, keyRec(0, u, keyUnicode), keyRec(0, u, keyUnicode|keyUp))
	}
	for i := 0; i < len(recs); i += 64 {
		end := min(i+64, len(recs))
		sendInputs(recs[i:end])
	}
}

func inputReleaseAll() {
	inMu.Lock()
	var recs []inputRec
	for vk := range keysDown {
		recs = append(recs, keyRec(vk, scanOf(vk), keyUp))
	}
	keysDown = map[uint16]bool{}
	for b, dn := range buttonsDown {
		if !dn {
			continue
		}
		flag := uint32(mouseLeftUp)
		if b == 2 {
			flag = mouseRightUp
		} else if b == 1 {
			flag = mouseMidUp
		}
		recs = append(recs, mouseRec(0, 0, 0, flag))
	}
	buttonsDown = map[int]bool{}
	inMu.Unlock()
	// 修飾鍵保險放開
	for _, vk := range []uint16{0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C} {
		recs = append(recs, keyRec(vk, scanOf(vk), keyUp))
	}
	sendInputs(recs)
}
