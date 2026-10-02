package main

import (
	"fmt"
	"os"
	"sync"
	"time"
)

var (
	logMu   sync.Mutex
	logFile *os.File
)

func openLog(path string) {
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		os.Rename(path, path+".old")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err == nil {
		logFile = f
	}
}

func logf(format string, a ...any) {
	line := time.Now().Format("[2006-01-02 15:04:05] ") + fmt.Sprintf(format, a...)
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Println(line)
	if logFile != nil {
		logFile.WriteString(line + "\n")
	}
}
