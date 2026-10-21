// Сервис по HTTPS для стенда шлюза: тот же /item, что у upstream.kh, сразу.
// CERT, KEY — сертификат (с цепочкой) и ключ; CLOSE=1 — закрывать соединение
// после каждого ответа, чтобы каждый запрос шлюза начинался с рукопожатия.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strconv"
)

type Item struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Price int    `json:"price"`
}

func main() {
	closeEach := os.Getenv("CLOSE") == "1"
	http.HandleFunc("GET /item", func(w http.ResponseWriter, r *http.Request) {
		id, _ := strconv.Atoi(r.URL.Query().Get("id"))
		if closeEach {
			w.Header().Set("Connection", "close")
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Item{id, "item " + strconv.Itoa(id), 1000 + id})
	})
	http.ListenAndServeTLS(":"+os.Getenv("PORT"), os.Getenv("CERT"), os.Getenv("KEY"), nil)
}
