package main

import (
	"encoding/json"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type Option struct {
	Text  string `json:"text"`
	Votes int    `json:"votes"`
}

type Poll struct {
	ID       int      `json:"id"`
	Question string   `json:"question"`
	Options  []Option `json:"options"`
	Closed   bool     `json:"closed"`
	voters   map[string]bool
}

type Result struct {
	Text    string  `json:"text"`
	Votes   int     `json:"votes"`
	Percent float64 `json:"percent"`
}

var (
	mu    sync.Mutex
	polls []*Poll
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// findPoll returns the poll from the path or answers 404; it must be called with mu held.
func findPoll(w http.ResponseWriter, r *http.Request) *Poll {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || id < 1 || id > len(polls) {
		http.NotFound(w, r)
		return nil
	}
	return polls[id-1]
}

func createPoll(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Question string   `json:"question"`
		Options  []string `json:"options"`
	}
	err := json.NewDecoder(r.Body).Decode(&req)
	valid := err == nil && strings.TrimSpace(req.Question) != "" && len(req.Options) >= 2 && len(req.Options) <= 10
	seen := map[string]bool{}
	for _, o := range req.Options {
		if strings.TrimSpace(o) == "" || seen[o] {
			valid = false
		}
		seen[o] = true
	}
	if !valid {
		http.Error(w, "question and 2-10 different options are required", http.StatusBadRequest)
		return
	}
	p := &Poll{Question: req.Question, voters: map[string]bool{}}
	for _, o := range req.Options {
		p.Options = append(p.Options, Option{Text: o})
	}
	mu.Lock()
	defer mu.Unlock()
	p.ID = len(polls) + 1
	polls = append(polls, p)
	writeJSON(w, http.StatusCreated, p)
}

func getPoll(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	if p := findPoll(w, r); p != nil {
		writeJSON(w, http.StatusOK, p)
	}
}

func listPolls(w http.ResponseWriter, r *http.Request) {
	open := r.URL.Query().Get("open")
	mu.Lock()
	defer mu.Unlock()
	list := []*Poll{}
	for _, p := range polls {
		if open == "" || (open == "true") != p.Closed {
			list = append(list, p)
		}
	}
	writeJSON(w, http.StatusOK, list)
}

func vote(w http.ResponseWriter, r *http.Request) {
	voter := r.Header.Get("X-Voter-Id")
	if voter == "" {
		http.Error(w, "X-Voter-Id is required", http.StatusUnauthorized)
		return
	}
	var req struct {
		Option int `json:"option"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	p := findPoll(w, r)
	if p == nil {
		return
	}
	if p.Closed {
		http.Error(w, "poll is closed", http.StatusForbidden)
		return
	}
	if req.Option < 0 || req.Option >= len(p.Options) {
		http.Error(w, "no such option", http.StatusBadRequest)
		return
	}
	if p.voters[voter] {
		http.Error(w, "already voted", http.StatusConflict)
		return
	}
	p.voters[voter] = true
	p.Options[req.Option].Votes++
	writeJSON(w, http.StatusOK, p)
}

func closePoll(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	if p := findPoll(w, r); p != nil {
		p.Closed = true
		writeJSON(w, http.StatusOK, p)
	}
}

func results(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	p := findPoll(w, r)
	if p == nil {
		return
	}
	total := 0
	for _, o := range p.Options {
		total += o.Votes
	}
	list := []Result{}
	for _, o := range p.Options {
		percent := 0.0
		if total > 0 {
			percent = math.Round(float64(o.Votes)*1000/float64(total)) / 10
		}
		list = append(list, Result{o.Text, o.Votes, percent})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].Votes > list[j].Votes })
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "results": list})
}

func main() {
	http.HandleFunc("POST /polls", createPoll)
	http.HandleFunc("GET /polls/{id}", getPoll)
	http.HandleFunc("GET /polls", listPolls)
	http.HandleFunc("POST /polls/{id}/votes", vote)
	http.HandleFunc("POST /polls/{id}/close", closePoll)
	http.HandleFunc("GET /polls/{id}/results", results)
	http.ListenAndServe(":8080", nil)
}
