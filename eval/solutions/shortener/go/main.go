package main

import (
	"crypto/rand"
	"encoding/json"
	"math/big"
	"net/http"
	"sort"
	"strings"
	"sync"
)

type Link struct {
	Code   string `json:"code"`
	URL    string `json:"url"`
	Clicks int    `json:"clicks"`
}

var (
	mu    sync.Mutex
	links = map[string]*Link{}
)

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

func randomCode() string {
	b := make([]byte, 7)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		b[i] = alphabet[n.Int64()]
	}
	return string(b)
}

func validCode(code string) bool {
	if len(code) < 3 || len(code) > 32 {
		return false
	}
	for _, c := range code {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func createLink(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL  string `json:"url"`
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if !strings.HasPrefix(req.URL, "http://") && !strings.HasPrefix(req.URL, "https://") {
		http.Error(w, "url must start with http:// or https://", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	code := req.Code
	if code == "" {
		for code == "" || links[code] != nil {
			code = randomCode()
		}
	} else if !validCode(code) {
		http.Error(w, "code must be 3-32 letters, digits, - or _", http.StatusBadRequest)
		return
	} else if links[code] != nil {
		http.Error(w, "code is taken", http.StatusConflict)
		return
	}
	link := &Link{Code: code, URL: req.URL}
	links[code] = link
	writeJSON(w, http.StatusCreated, link)
}

func redirect(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	link := links[r.PathValue("code")]
	if link != nil {
		link.Clicks++
	}
	mu.Unlock()
	if link == nil {
		http.NotFound(w, r)
		return
	}
	http.Redirect(w, r, link.URL, http.StatusFound)
}

func listLinks(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	list := make([]Link, 0, len(links))
	for _, l := range links {
		list = append(list, *l)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Clicks != list[j].Clicks {
			return list[i].Clicks > list[j].Clicks
		}
		return list[i].Code < list[j].Code
	})
	writeJSON(w, http.StatusOK, list)
}

func getLink(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	link := links[r.PathValue("code")]
	if link == nil {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, link)
}

func deleteLink(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	code := r.PathValue("code")
	if links[code] == nil {
		http.NotFound(w, r)
		return
	}
	delete(links, code)
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	http.HandleFunc("POST /links", createLink)
	http.HandleFunc("GET /links", listLinks)
	http.HandleFunc("GET /links/{code}", getLink)
	http.HandleFunc("DELETE /links/{code}", deleteLink)
	http.HandleFunc("GET /{code}", redirect)
	http.ListenAndServe(":8080", nil)
}
