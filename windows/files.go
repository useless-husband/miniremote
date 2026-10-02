package main

import (
	"archive/zip"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// 檔案瀏覽/下載/上傳,只允許在設定的根目錄之內
type Files struct {
	roots []string
}

func newFiles(cfgRoots []string) *Files {
	home, _ := os.UserHomeDir()
	var roots []string
	for _, r := range cfgRoots {
		switch {
		case r == "~":
			roots = append(roots, home)
		case strings.HasPrefix(r, "~/") || strings.HasPrefix(r, "~\\"):
			roots = append(roots, filepath.Join(home, r[2:]))
		case r == "*drives":
			if runtime.GOOS == "windows" {
				for c := 'A'; c <= 'Z'; c++ {
					d := string(c) + ":\\"
					if _, err := os.Stat(d); err == nil {
						roots = append(roots, d)
					}
				}
			}
		default:
			roots = append(roots, r)
		}
	}
	var ok []string
	for _, r := range roots {
		if abs, err := filepath.Abs(r); err == nil {
			if _, err := os.Stat(abs); err == nil {
				ok = append(ok, abs)
			}
		}
	}
	return &Files{roots: ok}
}

func norm(p string) string {
	p = filepath.Clean(p)
	if runtime.GOOS == "windows" {
		p = strings.ToLower(p)
	}
	return p
}

func withSep(p string) string {
	if strings.HasSuffix(p, string(filepath.Separator)) {
		return p
	}
	return p + string(filepath.Separator)
}

// 把使用者給的路徑正規化(解掉 .. 與符號連結),不在根目錄內就回 false
func (f *Files) resolve(raw string) (string, bool) {
	if raw == "" {
		return "", false
	}
	if raw == "~" || strings.HasPrefix(raw, "~/") {
		home, _ := os.UserHomeDir()
		raw = filepath.Join(home, strings.TrimPrefix(raw, "~"))
	}
	abs, err := filepath.Abs(raw)
	if err != nil {
		return "", false
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		abs = real
	}
	n := norm(abs)
	for _, root := range f.roots {
		rn := norm(root)
		if n == rn || strings.HasPrefix(withSep(n), withSep(rn)) {
			return abs, true
		}
	}
	return "", false
}

func (f *Files) isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

var hiddenNames = map[string]bool{
	"desktop.ini": true, "thumbs.db": true, "$recycle.bin": true, "system volume information": true,
	"ntuser.dat": true, "ntuser.ini": true, "pagefile.sys": true, "hiberfil.sys": true, "swapfile.sys": true,
	"dumpstack.log.tmp": true, "recovery": true, "config.msi": true,
}

func isHidden(name string) bool {
	if strings.HasPrefix(name, ".") || strings.HasPrefix(name, "$") {
		return true
	}
	l := strings.ToLower(name)
	return hiddenNames[l] || strings.HasPrefix(l, "ntuser.dat")
}

// 列出目錄;path 為空字串時列出所有根目錄
func (f *Files) list(raw string, showHidden bool) (map[string]any, bool) {
	home, _ := os.UserHomeDir()
	if raw == "" {
		entries := []map[string]any{}
		for _, r := range f.roots {
			name := r
			if norm(r) == norm(home) {
				name = "家目錄(" + home + ")"
			}
			entries = append(entries, map[string]any{"name": name, "path": r, "isDir": true, "size": 0, "mtime": 0})
		}
		return map[string]any{"path": "", "parent": nil, "entries": entries}, true
	}
	p, ok := f.resolve(raw)
	if !ok || !f.isDir(p) {
		return nil, false
	}
	items, err := os.ReadDir(p)
	if err != nil {
		return nil, false
	}
	entries := []map[string]any{}
	for _, it := range items {
		name := it.Name()
		if !showHidden && isHidden(name) {
			continue
		}
		full := filepath.Join(p, name)
		info, err := os.Stat(full) // 跟隨符號連結
		if err != nil {
			continue
		}
		entries = append(entries, map[string]any{
			"name": name, "path": full, "isDir": info.IsDir(), "isPackage": false,
			"size": info.Size(), "mtime": info.ModTime().Unix(),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		a, b := entries[i]["isDir"].(bool), entries[j]["isDir"].(bool)
		if a != b {
			return a
		}
		return strings.ToLower(entries[i]["name"].(string)) < strings.ToLower(entries[j]["name"].(string))
	})
	var parent any = filepath.Dir(p)
	for _, r := range f.roots {
		if norm(r) == norm(p) {
			parent = ""
		}
	}
	return map[string]any{"path": p, "parent": parent, "entries": entries}, true
}

// 上傳時避免覆蓋:同名就變成「名稱 (2).副檔名」
func (f *Files) uniqueDest(dir, name string) (string, bool) {
	safe := filepath.Base(strings.ReplaceAll(strings.ReplaceAll(name, "\\", "_"), "/", "_"))
	if safe == "" || safe == "." || safe == ".." {
		return "", false
	}
	cand := filepath.Join(dir, safe)
	ext := filepath.Ext(safe)
	base := strings.TrimSuffix(safe, ext)
	for n := 2; ; n++ {
		if _, err := os.Stat(cand); err != nil {
			return cand, true
		}
		cand = filepath.Join(dir, base+" ("+itoa(n)+")"+ext)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	return s
}

// 把資料夾串流壓成 zip 直接寫到 w
func (f *Files) zipDir(w io.Writer, dir string) error {
	zw := zip.NewWriter(w)
	base := filepath.Base(dir)
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		name := filepath.ToSlash(filepath.Join(base, rel))
		if d.IsDir() {
			if rel != "." {
				zw.Create(name + "/")
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		hdr, err := zip.FileInfoHeader(info)
		if err != nil {
			return nil
		}
		hdr.Name = name
		hdr.Method = zip.Deflate
		fw, err := zw.CreateHeader(hdr)
		if err != nil {
			return err
		}
		file, err := os.Open(p)
		if err != nil {
			return nil
		}
		_, err = io.Copy(fw, file)
		file.Close()
		return err
	})
	return zw.Close()
}
