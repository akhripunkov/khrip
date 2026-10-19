package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

const limit = 5

type window struct {
	start time.Time
	used  int
}

var (
	mu      sync.Mutex
	windows = map[string]*window{}
	length  = 60 * time.Second
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// active returns the key's current window or nil; it must be called with mu held.
func active(key string) *window {
	win := windows[key]
	if win == nil || time.Since(win.start) >= length {
		return nil
	}
	return win
}

func secondsLeft(w *window) int {
	left := time.Until(w.start.Add(length))
	return int((left + time.Second - 1) / time.Second)
}

// limited counts the request and calls next, or answers 401/429.
func limited(next func(w http.ResponseWriter, remaining int)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("X-API-Key")
		if key == "" {
			http.Error(w, "missing X-API-Key", http.StatusUnauthorized)
			return
		}
		mu.Lock()
		win := active(key)
		if win == nil {
			win = &window{start: time.Now()}
			windows[key] = win
		}
		if win.used >= limit {
			w.Header().Set("Retry-After", strconv.Itoa(secondsLeft(win)))
			mu.Unlock()
			http.Error(w, "too many requests", http.StatusTooManyRequests)
			return
		}
		win.used++
		remaining := limit - win.used
		mu.Unlock()
		next(w, remaining)
	}
}

func main() {
	if s, err := strconv.Atoi(os.Getenv("WINDOW_SECONDS")); err == nil {
		length = time.Duration(s) * time.Second
	}
	http.HandleFunc("GET /api/ping", limited(func(w http.ResponseWriter, remaining int) {
		writeJSON(w, http.StatusOK, map[string]any{"pong": true, "remaining": remaining})
	}))
	http.HandleFunc("GET /api/time", limited(func(w http.ResponseWriter, _ int) {
		writeJSON(w, http.StatusOK, map[string]string{"time": time.Now().UTC().Format(time.RFC3339)})
	}))
	http.HandleFunc("GET /limits/{key}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("key")
		mu.Lock()
		defer mu.Unlock()
		used, reset := 0, 0
		if win := active(key); win != nil {
			used, reset = win.used, secondsLeft(win)
		}
		writeJSON(w, http.StatusOK, map[string]any{"key": key, "used": used, "remaining": limit - used, "reset_in": reset})
	})
	http.ListenAndServe(":8080", nil)
}
