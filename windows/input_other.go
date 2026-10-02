//go:build !windows

package main

import "sync"

var warnOnce sync.Once

func warnInput() {
	warnOnce.Do(func() { logf("這個平台的版本不支援輸入注入(僅供測試)") })
}

func inputMouseMove(nx, ny float64, d Display)                          { warnInput() }
func inputMouseButton(button int, down bool, nx, ny float64, d Display) { warnInput() }
func inputScroll(dx, dy float64)                                        { warnInput() }
func inputKey(code, key string, down bool, mods int, cmdAsCtrl bool)    { warnInput() }
func inputText(s string)                                                { warnInput() }
func inputReleaseAll()                                                  {}
