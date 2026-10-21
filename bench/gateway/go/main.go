// Шлюз: цена товара из сервиса UPSTREAM с налогом 20%.
package main

import (
	"encoding/json"
	"net/http"
	"os"
)

type Item struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Price int    `json:"price"`
}

type Quote struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Total int    `json:"total"`
}

func main() {
	up := os.Getenv("UPSTREAM")
	if up == "" {
		up = "http://127.0.0.1:9090"
	}
	// по умолчанию Go держит 2 свободных соединения на хост — для шлюза мало
	client := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: 1024}}
	http.HandleFunc("GET /quote", func(w http.ResponseWriter, r *http.Request) {
		resp, err := client.Get(up + "/item?id=" + r.URL.Query().Get("id"))
		if err != nil {
			http.Error(w, "upstream failed", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		var it Item
		if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&it) != nil {
			http.Error(w, "upstream failed", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Quote{it.ID, it.Name, it.Price * 120 / 100})
	})
	http.ListenAndServe(":8080", nil)
}
