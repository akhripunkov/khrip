package main

import (
	"encoding/json"
	"math"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type Product struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Tags     []string `json:"tags"`
}

type Category struct {
	Name     string  `json:"name"`
	Count    int     `json:"count"`
	AvgPrice float64 `json:"avg_price"`
}

var (
	mu       sync.Mutex
	products []*Product
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func valid(p *Product) bool {
	return strings.TrimSpace(p.Name) != "" && strings.TrimSpace(p.Category) != "" && p.Price >= 0
}

func find(r *http.Request) *Product {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || id < 1 || id > len(products) {
		return nil
	}
	return products[id-1]
}

func createProduct(w http.ResponseWriter, r *http.Request) {
	p := &Product{Tags: []string{}}
	if err := json.NewDecoder(r.Body).Decode(p); err != nil || !valid(p) {
		http.Error(w, "name and category are required, price must not be negative", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	p.ID = len(products) + 1
	products = append(products, p)
	writeJSON(w, http.StatusCreated, p)
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	p := find(r)
	if p == nil {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func patchProduct(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	p := find(r)
	if p == nil {
		http.NotFound(w, r)
		return
	}
	updated := *p
	if err := json.NewDecoder(r.Body).Decode(&updated); err != nil || !valid(&updated) {
		http.Error(w, "name and category are required, price must not be negative", http.StatusBadRequest)
		return
	}
	updated.ID = p.ID
	*p = updated
	writeJSON(w, http.StatusOK, p)
}

func queryInt(r *http.Request, name string, def int) (int, bool) {
	s := r.URL.Query().Get(name)
	if s == "" {
		return def, true
	}
	n, err := strconv.Atoi(s)
	return n, err == nil
}

func listProducts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, ok1 := queryInt(r, "page", 1)
	perPage, ok2 := queryInt(r, "per_page", 10)
	if !ok1 || !ok2 || page < 1 || perPage < 1 || perPage > 100 {
		http.Error(w, "page must be at least 1, per_page from 1 to 100", http.StatusBadRequest)
		return
	}
	minPrice, maxPrice := math.Inf(-1), math.Inf(1)
	if s := q.Get("min_price"); s != "" {
		minPrice, _ = strconv.ParseFloat(s, 64)
	}
	if s := q.Get("max_price"); s != "" {
		maxPrice, _ = strconv.ParseFloat(s, 64)
	}
	needle := strings.ToLower(q.Get("q"))
	mu.Lock()
	items := []*Product{}
	for _, p := range products {
		if strings.Contains(strings.ToLower(p.Name), needle) &&
			(q.Get("category") == "" || p.Category == q.Get("category")) &&
			(q.Get("tag") == "" || slices.Contains(p.Tags, q.Get("tag"))) &&
			p.Price >= minPrice && p.Price <= maxPrice {
			items = append(items, p)
		}
	}
	mu.Unlock()
	switch q.Get("sort") {
	case "":
	case "price":
		sort.SliceStable(items, func(i, j int) bool { return items[i].Price < items[j].Price })
	case "-price":
		sort.SliceStable(items, func(i, j int) bool { return items[i].Price > items[j].Price })
	case "name":
		sort.SliceStable(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	default:
		http.Error(w, "sort must be price, -price or name", http.StatusBadRequest)
		return
	}
	start := min((page-1)*perPage, len(items))
	end := min(start+perPage, len(items))
	writeJSON(w, http.StatusOK, map[string]any{"items": items[start:end], "total": len(items), "page": page, "per_page": perPage})
}

func categories(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	byName := map[string]*Category{}
	for _, p := range products {
		c := byName[p.Category]
		if c == nil {
			c = &Category{Name: p.Category}
			byName[p.Category] = c
		}
		c.Count++
		c.AvgPrice += p.Price
	}
	mu.Unlock()
	list := []*Category{}
	for _, c := range byName {
		c.AvgPrice = math.Round(c.AvgPrice/float64(c.Count)*100) / 100
		list = append(list, c)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	writeJSON(w, http.StatusOK, list)
}

func main() {
	http.HandleFunc("POST /products", createProduct)
	http.HandleFunc("GET /products/{id}", getProduct)
	http.HandleFunc("PATCH /products/{id}", patchProduct)
	http.HandleFunc("GET /products", listProducts)
	http.HandleFunc("GET /categories", categories)
	http.ListenAndServe(":8080", nil)
}
