//go:build windows

package main

import (
	"runtime"
	"syscall"
)

var (
	kernel32                    = syscall.NewLazyDLL("kernel32.dll")
	procSetThreadExecutionState = kernel32.NewProc("SetThreadExecutionState")
	awakeCh                     = make(chan bool, 4)
)

func init() {
	// SetThreadExecutionState 是「執行緒」層級的,要在固定的執行緒上呼叫
	go func() {
		runtime.LockOSThread()
		for on := range awakeCh {
			if on {
				procSetThreadExecutionState.Call(0x80000000 | 0x1 | 0x2) // CONTINUOUS | SYSTEM | DISPLAY
			} else {
				procSetThreadExecutionState.Call(0x80000000)
			}
		}
	}()
}

func setAwake(on bool) {
	select {
	case awakeCh <- on:
	default:
	}
}
