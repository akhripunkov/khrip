package main

import (
	"encoding/json"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type Item struct {
	SKU   string `json:"sku"`
	Name  string `json:"name"`
	Stock int    `json:"stock"`
}

type Line struct {
	SKU string `json:"sku"`
	Qty int    `json:"qty"`
}

type Order struct {
	ID       int    `json:"id"`
	Lines    []Line `json:"lines"`
	Status   string `json:"status"`
	TotalQty int    `json:"total_qty"`
}

var (
	mu       sync.Mutex
	items    = map[string]*Item{}
	orders   []*Order
	skuRegex = regexp.MustCompile(`^[A-Z0-9-]{3,20}$`)
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func addItem(w http.ResponseWriter, r *http.Request) {
	var it Item
	if err := json.NewDecoder(r.Body).Decode(&it); err != nil || !skuRegex.MatchString(it.SKU) || strings.TrimSpace(it.Name) == "" || it.Stock < 0 {
		http.Error(w, "sku must be 3-20 of A-Z, 0-9, -; name required; stock >= 0", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if items[it.SKU] != nil {
		http.Error(w, "sku exists", http.StatusConflict)
		return
	}
	items[it.SKU] = &it
	writeJSON(w, http.StatusCreated, it)
}

func listItems(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	list := []*Item{}
	for _, it := range items {
		list = append(list, it)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].SKU < list[j].SKU })
	writeJSON(w, http.StatusOK, list)
}

func restock(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Amount int `json:"amount"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	mu.Lock()
	defer mu.Unlock()
	it := items[r.PathValue("sku")]
	if it == nil {
		http.NotFound(w, r)
		return
	}
	if req.Amount <= 0 {
		http.Error(w, "amount must be positive", http.StatusBadRequest)
		return
	}
	it.Stock += req.Amount
	writeJSON(w, http.StatusOK, it)
}

func placeOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Lines []Line `json:"lines"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Lines) == 0 {
		http.Error(w, "lines must not be empty", http.StatusBadRequest)
		return
	}
	need := map[string]int{}
	total := 0
	for _, l := range req.Lines {
		if l.Qty <= 0 {
			http.Error(w, "qty must be positive", http.StatusBadRequest)
			return
		}
		need[l.SKU] += l.Qty
		total += l.Qty
	}
	mu.Lock()
	defer mu.Unlock()
	for sku, qty := range need {
		it := items[sku]
		if it == nil {
			http.Error(w, "unknown sku "+sku, http.StatusNotFound)
			return
		}
		if it.Stock < qty {
			http.Error(w, "not enough "+sku, http.StatusConflict)
			return
		}
	}
	for sku, qty := range need {
		items[sku].Stock -= qty
	}
	o := &Order{ID: len(orders) + 1, Lines: req.Lines, Status: "placed", TotalQty: total}
	orders = append(orders, o)
	writeJSON(w, http.StatusCreated, o)
}

func cancelOrder(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(r.PathValue("id"))
	mu.Lock()
	defer mu.Unlock()
	if id < 1 || id > len(orders) {
		http.NotFound(w, r)
		return
	}
	o := orders[id-1]
	if o.Status == "cancelled" {
		http.Error(w, "already cancelled", http.StatusConflict)
		return
	}
	o.Status = "cancelled"
	for _, l := range o.Lines {
		items[l.SKU].Stock += l.Qty
	}
	writeJSON(w, http.StatusOK, o)
}

func listOrders(w http.ResponseWriter, r *http.Request) {
	status := r.URL.Query().Get("status")
	if status != "" && status != "placed" && status != "cancelled" {
		http.Error(w, "status must be placed or cancelled", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	list := []*Order{}
	for _, o := range orders {
		if status == "" || o.Status == status {
			list = append(list, o)
		}
	}
	writeJSON(w, http.StatusOK, list)
}

func main() {
	http.HandleFunc("POST /items", addItem)
	http.HandleFunc("GET /items", listItems)
	http.HandleFunc("POST /items/{sku}/restock", restock)
	http.HandleFunc("POST /orders", placeOrder)
	http.HandleFunc("POST /orders/{id}/cancel", cancelOrder)
	http.HandleFunc("GET /orders", listOrders)
	http.ListenAndServe(":8080", nil)
}
