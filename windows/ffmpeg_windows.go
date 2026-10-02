//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

func exeSuffix() string          { return ".exe" }
func defaultFileRoots() []string { return []string{"~", "*drives"} }
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

func runQuiet(ffmpeg string, args ...string) bool {
	cmd := exec.Command(ffmpeg, args...)
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	if err != nil {
		logf("探測失敗 %v:%s", args[len(args)-3], lastLine(string(out)))
	}
	return err == nil
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// 探測這台有哪些硬體編碼器、哪種擷取方式可用
func probeEncoders(ffmpeg, prefer, capture string) EncoderInfo {
	info := EncoderInfo{Capture: "gdigrab"}
	listCmd := exec.Command(ffmpeg, "-hide_banner", "-encoders")
	hideWindow(listCmd)
	listing, err := listCmd.Output()
	if err != nil {
		logf("執行 ffmpeg 失敗:%v(路徑 %s)", err, ffmpeg)
		return info
	}
	have := func(name string) bool { return strings.Contains(string(listing), " "+name+" ") }
	test := func(enc string) bool {
		return have(enc) && runQuiet(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=black:s=320x240:r=30",
			"-frames:v", "3", "-c:v", enc, "-f", "null", "-")
	}
	order := map[string][]string{
		"nvenc": {"nvenc"}, "qsv": {"qsv"}, "amf": {"amf"}, "x264": {},
		"auto": {"nvenc", "qsv", "amf"},
	}[prefer]
	if order == nil {
		order = []string{"nvenc", "qsv", "amf"}
	}
	for _, v := range order {
		if info.H264 == "" && test("h264_"+v) {
			info.H264 = "h264_" + v
		}
		if info.HEVC == "" && test("hevc_"+v) {
			info.HEVC = "hevc_" + v
		}
	}
	if info.H264 == "" && test("libx264") {
		info.H264 = "libx264"
	}
	// HEVC 軟體編碼太吃 CPU,不採用
	switch capture {
	case "ddagrab", "gdigrab":
		info.Capture = capture
	default:
		if runQuiet(ffmpeg, "-hide_banner", "-loglevel", "error", "-init_hw_device", "d3d11va", "-filter_complex",
			"ddagrab=framerate=5:output_idx=0,hwdownload,format=bgra", "-frames:v", "1", "-f", "null", "-") {
			info.Capture = "ddagrab"
		}
	}
	return info
}

func buildFFmpegArgs(enc EncoderInfo, p CaptureParams) []string {
	pix := "yuv420p"
	if p.Codec == "jpeg" {
		pix = "yuvj420p"
	}
	scale := fmt.Sprintf("scale=%d:%d:flags=fast_bilinear,format=%s", p.W, p.H, pix)
	args := []string{"-hide_banner", "-loglevel", "warning", "-nostdin", "-fflags", "nobuffer", "-flags", "low_delay"}
	if enc.Capture == "ddagrab" {
		args = append(args, "-init_hw_device", "d3d11va", "-filter_complex",
			fmt.Sprintf("ddagrab=output_idx=%d:framerate=%d:draw_mouse=1,hwdownload,format=bgra,%s", p.Display.Index, p.FPS, scale))
	} else {
		args = append(args, "-f", "gdigrab", "-framerate", itoa(p.FPS), "-offset_x", itoa(p.Display.X), "-offset_y", itoa(p.Display.Y),
			"-video_size", fmt.Sprintf("%dx%d", p.Display.W, p.Display.H), "-draw_mouse", "1", "-rtbufsize", "256M", "-i", "desktop",
			"-vf", scale)
	}
	kb := itoa(p.Bitrate) + "k"
	g := itoa(p.FPS * 2)
	switch p.Codec {
	case "jpeg":
		q := int(2 + (1-p.Quality)*29) // 品質 1.0 → q 2,0.1 → q 28
		args = append(args, "-c:v", "mjpeg", "-q:v", itoa(q), "-f", "image2pipe", "-")
	default:
		name := enc.H264
		if p.Codec == "hevc" {
			name = enc.HEVC
		}
		args = append(args, "-c:v", name)
		switch {
		case strings.HasSuffix(name, "_nvenc"):
			args = append(args, "-preset", "p1", "-tune", "ll", "-rc", "vbr", "-zerolatency", "1", "-delay", "0", "-bf", "0", "-g", g, "-b:v", kb, "-maxrate", kb, "-bufsize", kb)
			if p.Codec == "hevc" {
				args = append(args, "-profile:v", "main")
			}
		case strings.HasSuffix(name, "_qsv"):
			args = append(args, "-preset", "veryfast", "-bf", "0", "-g", g, "-b:v", kb, "-maxrate", kb, "-bufsize", kb, "-async_depth", "1")
		case strings.HasSuffix(name, "_amf"):
			args = append(args, "-usage", "lowlatency", "-quality", "speed", "-rc", "vbr_latency", "-bf", "0", "-g", g, "-b:v", kb, "-maxrate", kb, "-bufsize", kb)
		default: // libx264
			args = append(args, "-preset", "ultrafast", "-tune", "zerolatency", "-x264-params",
				fmt.Sprintf("keyint=%s:min-keyint=%s:scenecut=0:bframes=0:rc-lookahead=0:sync-lookahead=0:sliced-threads=1", g, g),
				"-b:v", kb, "-maxrate", kb, "-bufsize", kb)
		}
		args = append(args, "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709")
		if p.Codec == "hevc" {
			args = append(args, "-tag:v", "hvc1")
		}
		args = append(args, "-f", "mp4", "-movflags", "frag_every_frame+empty_moov+default_base_moof+omit_tfhd_offset", "-flush_packets", "1", "-")
	}
	return args
}
