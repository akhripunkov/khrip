// Перенос bench/gc/delete.kh на Go (этап памяти, часть 1): 200 тысяч товаров,
// затем удаляются 90% — старые подряд (oldest) или вразнобой (random), затем
// простой. Сборщик Go тоже не перемещает объекты: сравнение показывает, общий
// ли это предел. GET /stats — «товаров живое куча сборок» (байт: HeapAlloc и
// HeapInuse после принудительной сборки — как живое по последней сборке у
// Khrip); POST /free — debug.FreeOSMemory.
package main

import (
	"fmt"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
)

type Product struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Tags     []string `json:"tags"`
}

var (
	mu       sync.Mutex
	products = map[int]*Product{}
)

func main() {
	http.HandleFunc("POST /fill/{n}", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.PathValue("n"))
		mu.Lock()
		start := len(products)
		for i := start; i < start+n; i++ {
			products[i] = &Product{ID: i, Name: fmt.Sprintf("Product number %d with a name", i),
				Category: fmt.Sprintf("category %d", i%40), Price: float64(i) / 7.0,
				Tags: []string{fmt.Sprintf("t%d", i%13), "all"}}
		}
		l := len(products)
		mu.Unlock()
		fmt.Fprint(w, l)
	})
	http.HandleFunc("POST /delete/{how}/{n}", func(w http.ResponseWriter, r *http.Request) {
		how := r.PathValue("how")
		n, _ := strconv.Atoi(r.PathValue("n"))
		mu.Lock()
		for i := 0; i < n; i++ {
			if how == "oldest" {
				if i < n*9/10 {
					delete(products, i)
				}
			} else if (i*7919)%10 != 0 {
				delete(products, i)
			}
		}
		l := len(products)
		mu.Unlock()
		fmt.Fprint(w, l)
	})
	http.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		mu.Lock()
		l := len(products)
		mu.Unlock()
		fmt.Fprintf(w, "%d %d %d %d", l, m.HeapAlloc, m.HeapInuse, m.NumGC)
	})
	// всё свободное — системе сразу (нижняя граница RSS после сборки)
	http.HandleFunc("POST /free", func(w http.ResponseWriter, r *http.Request) {
		debug.FreeOSMemory()
		fmt.Fprint(w, "ok")
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	http.ListenAndServe(":"+port, nil)
}
