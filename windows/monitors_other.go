//go:build !windows

package main

func listDisplays() []Display {
	return []Display{{Index: 0, W: 1920, H: 1080, Primary: true, Name: "測試圖樣"}}
}
