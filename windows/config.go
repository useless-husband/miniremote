package main

import (
	"bytes"
	"encoding/json"
	"os"
)

type Peer struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type Config struct {
	Port                   int      `json:"port"`
	Password               string   `json:"password"`
	Name                   string   `json:"name"`
	FPS                    int      `json:"fps"`
	BitrateKbps            int      `json:"bitrateKbps"`
	AutoBitrate            bool     `json:"autoBitrate"`
	JpegQuality            float64  `json:"jpegQuality"`
	MaxHeight              int      `json:"maxHeight"`
	AllowLAN               bool     `json:"allowLAN"`
	AllowedTailscaleLogins []string `json:"allowedTailscaleLogins"`
	FileRoots              []string `json:"fileRoots"`
	SessionDays            int      `json:"sessionDays"`
	IdleStopSeconds        int      `json:"idleStopSeconds"`
	FFmpeg                 string   `json:"ffmpeg"`
	Encoder                string   `json:"encoder"` // auto | nvenc | qsv | amf | x264
	Capture                string   `json:"capture"` // auto | ddagrab | gdigrab
	CmdAsCtrl              bool     `json:"cmdAsCtrl"`
	Peers                  []Peer   `json:"peers"`
}

func defaultConfig() Config {
	return Config{
		Port: 8800, Name: "Windows", FPS: 30, BitrateKbps: 12000, AutoBitrate: true, JpegQuality: 0.6,
		FileRoots: defaultFileRoots(), SessionDays: 30, IdleStopSeconds: 60,
		Encoder: "auto", Capture: "auto", CmdAsCtrl: true,
	}
}

func loadConfig(path string) Config {
	cfg := defaultConfig()
	data, err := os.ReadFile(path)
	if err != nil {
		logf("找不到設定檔 %s,使用預設值(沒有密碼!)", path)
		return cfg
	}
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}) // PowerShell 寫的檔案會帶 UTF-8 BOM
	if err := json.Unmarshal(data, &cfg); err != nil {
		logf("設定檔格式錯誤 %s:%v,使用預設值", path, err)
		return defaultConfig()
	}
	if cfg.Port <= 0 {
		cfg.Port = 8800
	}
	return cfg
}
