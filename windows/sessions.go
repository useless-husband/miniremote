package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"os"
	"sync"
	"time"
)

const (
	maxFailures = 8
	lockMinutes = 15
)

type failInfo struct {
	count       int
	lockedUntil time.Time
}

// 登入 token 與密碼錯誤鎖定;token 只存 SHA-256
type Sessions struct {
	path     string
	days     int
	mu       sync.Mutex
	list     []map[string]any
	failures map[string]*failInfo
}

func newSessions(path string, days int) *Sessions {
	s := &Sessions{path: path, days: days, failures: map[string]*failInfo{}}
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &s.list)
	}
	return s
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func passwordMatches(given, expected string) bool {
	return subtle.ConstantTimeCompare([]byte(sha256Hex(given)), []byte(sha256Hex(expected))) == 1
}

func (s *Sessions) save() {
	data, _ := json.MarshalIndent(s.list, "", "  ")
	os.WriteFile(s.path, data, 0o600)
}

func (s *Sessions) issue(label string) string {
	b := make([]byte, 32)
	rand.Read(b)
	token := hex.EncodeToString(b)
	now := float64(time.Now().Unix())
	s.mu.Lock()
	s.list = append(s.list, map[string]any{"hash": sha256Hex(token), "created": now, "lastUsed": now, "label": label})
	s.save()
	s.mu.Unlock()
	return token
}

func (s *Sessions) validate(token string) bool {
	if token == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := float64(time.Now().Unix()) - float64(s.days)*86400
	kept := s.list[:0]
	for _, e := range s.list {
		if c, _ := e["created"].(float64); c >= cutoff {
			kept = append(kept, e)
		}
	}
	if len(kept) != len(s.list) {
		s.list = kept
		s.save()
	}
	h := sha256Hex(token)
	for _, e := range s.list {
		if eh, _ := e["hash"].(string); subtle.ConstantTimeCompare([]byte(eh), []byte(h)) == 1 {
			e["lastUsed"] = float64(time.Now().Unix())
			return true
		}
	}
	return false
}

func (s *Sessions) revoke(token string) {
	h := sha256Hex(token)
	s.mu.Lock()
	kept := s.list[:0]
	for _, e := range s.list {
		if eh, _ := e["hash"].(string); eh != h {
			kept = append(kept, e)
		}
	}
	s.list = kept
	s.save()
	s.mu.Unlock()
}

func (s *Sessions) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.list)
}

func (s *Sessions) lockedSeconds(ip string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.failures[ip]
	if f == nil || f.count < maxFailures {
		return 0
	}
	remain := time.Until(f.lockedUntil)
	if remain <= 0 {
		delete(s.failures, ip)
		return 0
	}
	return int(remain.Seconds()) + 1
}

func (s *Sessions) recordFailure(ip string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.failures[ip]
	if f == nil {
		f = &failInfo{}
		s.failures[ip] = f
	}
	f.count++
	if f.count >= maxFailures {
		f.lockedUntil = time.Now().Add(lockMinutes * time.Minute)
	}
	return f.count
}

func (s *Sessions) clearFailures(ip string) {
	s.mu.Lock()
	delete(s.failures, ip)
	s.mu.Unlock()
}
