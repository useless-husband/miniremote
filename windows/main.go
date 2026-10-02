package main

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
)

func main() {
	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)
	cfgPath := flag.String("config", filepath.Join(exeDir, "config.json"), "設定檔路徑")
	flag.Parse()
	dir := filepath.Dir(*cfgPath)
	openLog(filepath.Join(dir, "MiniRemote.log"))
	cfg := loadConfig(*cfgPath)
	if cfg.FFmpeg == "" {
		cfg.FFmpeg = findFFmpeg(dir, exeDir)
	}
	warn := ""
	if cfg.Password == "" {
		warn = ",⚠️ 沒有設定密碼"
	}
	logf("MiniRemote(Windows 版)啟動,設定檔 %s,port %d%s", *cfgPath, cfg.Port, warn)
	s := newServer(cfg, dir)
	if err := s.run(); err != nil {
		logf("伺服器結束:%v", err)
		os.Exit(1)
	}
}

func findFFmpeg(dirs ...string) string {
	names := []string{"ffmpeg" + exeSuffix()}
	for _, d := range dirs {
		for _, n := range names {
			p := filepath.Join(d, n)
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	return "ffmpeg" + exeSuffix()
}
