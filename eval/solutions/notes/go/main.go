package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	salt     []byte
	hash     []byte
}

type Note struct {
	ID        int    `json:"id"`
	Title     string `json:"title"`
	Text      string `json:"text"`
	CreatedAt string `json:"created_at"`
	owner     string
}

var (
	mu       sync.Mutex
	users    = map[string]*User{}
	sessions = map[string]string{}
	notes    = map[int]*Note{}
	lastNote = 0
)

func hashPassword(password string, salt []byte) []byte {
	key, _ := pbkdf2.Key(sha256.New, password, salt, 100000, 32)
	return key
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func register(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil || utf8.RuneCountInString(c.Username) < 3 || utf8.RuneCountInString(c.Username) > 32 || utf8.RuneCountInString(c.Password) < 8 {
		http.Error(w, "username must be 3-32 characters, password at least 8", http.StatusBadRequest)
		return
	}
	salt := make([]byte, 16)
	rand.Read(salt)
	hash := hashPassword(c.Password, salt)
	mu.Lock()
	defer mu.Unlock()
	if users[c.Username] != nil {
		http.Error(w, "username is taken", http.StatusConflict)
		return
	}
	u := &User{ID: len(users) + 1, Username: c.Username, salt: salt, hash: hash}
	users[c.Username] = u
	writeJSON(w, http.StatusCreated, u)
}

func login(w http.ResponseWriter, r *http.Request) {
	var c credentials
	json.NewDecoder(r.Body).Decode(&c)
	mu.Lock()
	u := users[c.Username]
	mu.Unlock()
	if u == nil || subtle.ConstantTimeCompare(hashPassword(c.Password, u.salt), u.hash) != 1 {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	token := rand.Text()
	mu.Lock()
	sessions[token] = u.Username
	mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

// auth returns the user of the bearer token; it must be called with mu held.
func auth(w http.ResponseWriter, r *http.Request) (string, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	user, found := sessions[token]
	if !ok || !found {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return "", false
	}
	return user, true
}

func createNote(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	user, ok := auth(w, r)
	if !ok {
		return
	}
	var n Note
	if err := json.NewDecoder(r.Body).Decode(&n); err != nil || strings.TrimSpace(n.Title) == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	lastNote++
	n.ID, n.owner, n.CreatedAt = lastNote, user, time.Now().UTC().Format(time.RFC3339)
	notes[n.ID] = &n
	writeJSON(w, http.StatusCreated, n)
}

func listNotes(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	user, ok := auth(w, r)
	if !ok {
		return
	}
	list := []*Note{}
	for _, n := range notes {
		if n.owner == user {
			list = append(list, n)
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	writeJSON(w, http.StatusOK, list)
}

// ownNote finds the caller's note from the path; it must be called with mu held.
func ownNote(w http.ResponseWriter, r *http.Request) *Note {
	user, ok := auth(w, r)
	if !ok {
		return nil
	}
	id, _ := strconv.Atoi(r.PathValue("id"))
	n := notes[id]
	if n == nil || n.owner != user {
		http.NotFound(w, r)
		return nil
	}
	return n
}

func getNote(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	if n := ownNote(w, r); n != nil {
		writeJSON(w, http.StatusOK, n)
	}
}

func deleteNote(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	if n := ownNote(w, r); n != nil {
		delete(notes, n.ID)
		w.WriteHeader(http.StatusNoContent)
	}
}

func main() {
	http.HandleFunc("POST /register", register)
	http.HandleFunc("POST /login", login)
	http.HandleFunc("POST /notes", createNote)
	http.HandleFunc("GET /notes", listNotes)
	http.HandleFunc("GET /notes/{id}", getNote)
	http.HandleFunc("DELETE /notes/{id}", deleteNote)
	http.ListenAndServe(":8080", nil)
}
