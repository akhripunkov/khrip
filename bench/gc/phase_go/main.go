// Перенос bench/gc/phase.kh на Go (этап памяти, часть 1b): рост, затем замены.
// GET /stats — «записей живое куча сборок» (HeapAlloc и HeapInuse после
// принудительной сборки, поэтому его просят только в конце).
package main

import (
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
)

type Item struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Payload string `json:"payload"`
}

var (
	mu    sync.Mutex
	items = map[int]*Item{}
)

func main() {
	http.HandleFunc("POST /fill/{n}", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.PathValue("n"))
		mu.Lock()
		start := len(items)
		for i := start; i < start+n; i++ {
			items[i] = &Item{ID: i, Name: fmt.Sprintf("item number %d", i), Payload: fmt.Sprintf("payload of the item number %d", i)}
		}
		l := len(items)
		mu.Unlock()
		fmt.Fprint(w, l)
	})
	http.HandleFunc("POST /churn/{from}/{n}", func(w http.ResponseWriter, r *http.Request) {
		from, _ := strconv.Atoi(r.PathValue("from"))
		n, _ := strconv.Atoi(r.PathValue("n"))
		mu.Lock()
		total := len(items)
		for k := 0; k < n; k++ {
			i := (from + k) % total
			items[i] = &Item{ID: i, Name: fmt.Sprintf("item number %d", i), Payload: fmt.Sprintf("replaced payload of the item %d", from)}
		}
		mu.Unlock()
		fmt.Fprint(w, total)
	})
	http.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		mu.Lock()
		l := len(items)
		mu.Unlock()
		fmt.Fprintf(w, "%d %d %d %d", l, m.HeapAlloc, m.HeapInuse, m.NumGC)
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	http.ListenAndServe(":"+port, nil)
}
