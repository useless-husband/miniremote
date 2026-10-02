//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

var (
	procEnumDisplayMonitors           = user32.NewProc("EnumDisplayMonitors")
	procGetMonitorInfoW               = user32.NewProc("GetMonitorInfoW")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
)

type winRect struct{ L, T, R, B int32 }

type monitorInfoEx struct {
	CbSize  uint32
	Monitor winRect
	Work    winRect
	Flags   uint32
	Device  [32]uint16
}

func setDPIAware() {
	// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4,這樣拿到的座標才是實際像素
	if r, _, _ := procSetProcessDpiAwarenessContext.Call(^uintptr(3)); r == 0 {
		procSetProcessDPIAware.Call()
	}
}

func listDisplays() []Display {
	setDPIAware()
	var out []Display
	cb := syscall.NewCallback(func(hMon, hdc, lprc, lparam uintptr) uintptr {
		var mi monitorInfoEx
		mi.CbSize = uint32(unsafe.Sizeof(mi))
		procGetMonitorInfoW.Call(hMon, uintptr(unsafe.Pointer(&mi)))
		out = append(out, Display{
			Index: len(out), X: int(mi.Monitor.L), Y: int(mi.Monitor.T),
			W: int(mi.Monitor.R - mi.Monitor.L), H: int(mi.Monitor.B - mi.Monitor.T),
			Primary: mi.Flags&1 != 0, Name: syscall.UTF16ToString(mi.Device[:]),
		})
		return 1
	})
	procEnumDisplayMonitors.Call(0, 0, cb, 0)
	if len(out) == 0 {
		out = []Display{{Index: 0, W: metric(0), H: metric(1), Primary: true, Name: "Display"}}
	}
	return out
}
