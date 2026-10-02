//go:build !windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// 非 Windows(開發測試用):畫面來源是 ffmpeg 的測試圖樣,編碼用 VideoToolbox 或 libx264

func exeSuffix() string          { return "" }
func defaultFileRoots() []string { return []string{"~", "/Volumes"} }
func hideWindow(cmd *exec.Cmd)   {}

func probeEncoders(ffmpeg, prefer, capture string) EncoderInfo {
	info := EncoderInfo{Capture: "testsrc"}
	out, err := exec.Command(ffmpeg, "-hide_banner", "-encoders").Output()
	if err != nil {
		logf("執行 ffmpeg 失敗:%v", err)
		return info
	}
	have := func(n string) bool { return strings.Contains(string(out), " "+n+" ") }
	if prefer != "x264" && have("h264_videotoolbox") {
		info.H264 = "h264_videotoolbox"
	} else if have("libx264") {
		info.H264 = "libx264"
	}
	if have("hevc_videotoolbox") {
		info.HEVC = "hevc_videotoolbox"
	}
	return info
}

func buildFFmpegArgs(enc EncoderInfo, p CaptureParams) []string {
	pix := "yuv420p"
	if p.Codec == "jpeg" {
		pix = "yuvj420p"
	}
	args := []string{"-hide_banner", "-loglevel", "warning", "-nostdin", "-re", "-f", "lavfi", "-i",
		fmt.Sprintf("testsrc2=size=%dx%d:rate=%d", p.W, p.H, p.FPS), "-vf", "format=" + pix}
	kb := itoa(p.Bitrate) + "k"
	g := itoa(p.FPS * 2)
	switch p.Codec {
	case "jpeg":
		q := int(2 + (1-p.Quality)*29)
		args = append(args, "-c:v", "mjpeg", "-q:v", itoa(q), "-f", "image2pipe", "-")
	default:
		name := enc.H264
		if p.Codec == "hevc" {
			name = enc.HEVC
		}
		args = append(args, "-c:v", name)
		if strings.HasSuffix(name, "_videotoolbox") {
			args = append(args, "-realtime", "1", "-prio_speed", "1", "-allow_sw", "1", "-bf", "0", "-g", g, "-b:v", kb)
		} else {
			args = append(args, "-preset", "ultrafast", "-tune", "zerolatency", "-x264-params",
				fmt.Sprintf("keyint=%s:min-keyint=%s:scenecut=0:bframes=0:rc-lookahead=0:sync-lookahead=0", g, g), "-b:v", kb, "-maxrate", kb, "-bufsize", kb)
		}
		args = append(args, "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709")
		if p.Codec == "hevc" {
			args = append(args, "-tag:v", "hvc1")
		}
		args = append(args, "-f", "mp4", "-movflags", "frag_every_frame+empty_moov+default_base_moof+omit_tfhd_offset", "-flush_packets", "1", "-")
	}
	return args
}
