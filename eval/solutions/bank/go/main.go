package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Account struct {
	ID      int    `json:"id"`
	Owner   string `json:"owner"`
	Balance int    `json:"balance"`
}

type Transfer struct {
	ID        int    `json:"id"`
	FromID    int    `json:"from_id"`
	ToID      int    `json:"to_id"`
	Amount    int    `json:"amount"`
	CreatedAt string `json:"created_at"`
}

var (
	mu        sync.Mutex
	accounts  = map[int]*Account{}
	transfers []Transfer
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func pathID(r *http.Request) int {
	id, _ := strconv.Atoi(r.PathValue("id"))
	return id
}

func createAccount(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Owner string `json:"owner"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Owner) == "" {
		http.Error(w, "owner is required", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	acc := &Account{ID: len(accounts) + 1, Owner: req.Owner}
	accounts[acc.ID] = acc
	writeJSON(w, http.StatusCreated, acc)
}

func getAccount(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	acc := accounts[pathID(r)]
	if acc == nil {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, acc)
}

func deposit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Amount int `json:"amount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	acc := accounts[pathID(r)]
	if acc == nil {
		http.NotFound(w, r)
		return
	}
	if req.Amount <= 0 {
		http.Error(w, "amount must be positive", http.StatusBadRequest)
		return
	}
	acc.Balance += req.Amount
	writeJSON(w, http.StatusOK, acc)
}

func transfer(w http.ResponseWriter, r *http.Request) {
	var req Transfer
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if req.Amount <= 0 || req.FromID == req.ToID {
		http.Error(w, "amount must be positive and accounts different", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	from, to := accounts[req.FromID], accounts[req.ToID]
	if from == nil || to == nil {
		http.NotFound(w, r)
		return
	}
	if from.Balance < req.Amount {
		http.Error(w, "insufficient funds", http.StatusConflict)
		return
	}
	from.Balance -= req.Amount
	to.Balance += req.Amount
	t := Transfer{ID: len(transfers) + 1, FromID: req.FromID, ToID: req.ToID, Amount: req.Amount,
		CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	transfers = append(transfers, t)
	writeJSON(w, http.StatusCreated, t)
}

func history(w http.ResponseWriter, r *http.Request) {
	id := pathID(r)
	mu.Lock()
	defer mu.Unlock()
	if accounts[id] == nil {
		http.NotFound(w, r)
		return
	}
	list := []Transfer{}
	for i := len(transfers) - 1; i >= 0; i-- {
		if t := transfers[i]; t.FromID == id || t.ToID == id {
			list = append(list, t)
		}
	}
	writeJSON(w, http.StatusOK, list)
}

func main() {
	http.HandleFunc("POST /accounts", createAccount)
	http.HandleFunc("GET /accounts/{id}", getAccount)
	http.HandleFunc("POST /accounts/{id}/deposit", deposit)
	http.HandleFunc("POST /transfers", transfer)
	http.HandleFunc("GET /accounts/{id}/transfers", history)
	http.ListenAndServe(":8080", nil)
}
