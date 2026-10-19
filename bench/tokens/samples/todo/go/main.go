package main

import (
	"encoding/json"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type Task struct {
	ID     int      `json:"id"`
	Title  string   `json:"title"`
	Status string   `json:"status"`
	Tags   []string `json:"tags"`
}

type Stats struct {
	Total int `json:"total"`
	Done  int `json:"done"`
	Open  int `json:"open"`
}

var (
	mu     sync.Mutex
	tasks  = map[int]*Task{}
	lastID = 0
)

func validStatus(s string) bool {
	return s == "Todo" || s == "Doing" || s == "Done"
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func createTask(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title  string   `json:"title"`
		Status string   `json:"status"`
		Tags   []string `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(in.Title) == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	if in.Status == "" {
		in.Status = "Todo"
	}
	if !validStatus(in.Status) {
		http.Error(w, "invalid status", http.StatusBadRequest)
		return
	}
	if in.Tags == nil {
		in.Tags = []string{}
	}
	mu.Lock()
	lastID++
	t := &Task{ID: lastID, Title: in.Title, Status: in.Status, Tags: in.Tags}
	tasks[t.ID] = t
	mu.Unlock()
	writeJSON(w, http.StatusCreated, t)
}

func listTasks(w http.ResponseWriter, r *http.Request) {
	status := r.URL.Query().Get("status")
	tag := r.URL.Query().Get("tag")
	if status != "" && !validStatus(status) {
		http.Error(w, "invalid status", http.StatusBadRequest)
		return
	}
	mu.Lock()
	list := []*Task{}
	for _, t := range tasks {
		if (status == "" || t.Status == status) && (tag == "" || slices.Contains(t.Tags, tag)) {
			list = append(list, t)
		}
	}
	sort.Slice(list, func(a, b int) bool { return list[a].Title < list[b].Title })
	writeJSON(w, http.StatusOK, list)
	mu.Unlock()
}

func getTask(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	t, ok := tasks[id]
	if !ok {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func setStatus(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	status := r.URL.Query().Get("status")
	if !validStatus(status) {
		http.Error(w, "invalid status", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	t, ok := tasks[id]
	if !ok {
		http.NotFound(w, r)
		return
	}
	t.Status = status
	writeJSON(w, http.StatusOK, t)
}

func stats(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	s := Stats{Total: len(tasks)}
	for _, t := range tasks {
		if t.Status == "Done" {
			s.Done++
		}
	}
	mu.Unlock()
	s.Open = s.Total - s.Done
	writeJSON(w, http.StatusOK, s)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /tasks", createTask)
	mux.HandleFunc("GET /tasks", listTasks)
	mux.HandleFunc("GET /tasks/{id}", getTask)
	mux.HandleFunc("PUT /tasks/{id}/status", setStatus)
	mux.HandleFunc("GET /stats", stats)
	http.ListenAndServe(":8080", mux)
}
