package main

import (
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type User struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Age   int    `json:"age"`
}

type NewUser struct {
	Name  string `json:"name"`
	Email string `json:"email"`
	Age   int    `json:"age"`
}

var (
	mu     sync.Mutex
	users  = map[int]User{}
	nextID = 1
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func createUser(w http.ResponseWriter, r *http.Request) {
	var in NewUser
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if in.Name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}
	if !strings.Contains(in.Email, "@") {
		http.Error(w, "email is invalid", http.StatusBadRequest)
		return
	}
	if in.Age < 0 || in.Age > 150 {
		http.Error(w, "age is out of range", http.StatusBadRequest)
		return
	}
	mu.Lock()
	u := User{ID: nextID, Name: in.Name, Email: in.Email, Age: in.Age}
	users[u.ID] = u
	nextID++
	mu.Unlock()
	writeJSON(w, http.StatusCreated, u)
}

func getUser(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	mu.Lock()
	u, ok := users[id]
	mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, u)
}

func listUsers(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	list := make([]User, 0, len(users))
	for _, u := range users {
		list = append(list, u)
	}
	mu.Unlock()
	sort.Slice(list, func(a, b int) bool { return list[a].ID < list[b].ID })
	writeJSON(w, http.StatusOK, list)
}

func deleteUser(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	mu.Lock()
	_, ok := users[id]
	delete(users, id)
	mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /users", createUser)
	mux.HandleFunc("GET /users/{id}", getUser)
	mux.HandleFunc("GET /users", listUsers)
	mux.HandleFunc("DELETE /users/{id}", deleteUser)
	http.ListenAndServe(":8080", mux)
}
