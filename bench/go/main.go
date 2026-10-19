// Эталонный сервер на Go: только стандартная библиотека (net/http, encoding/json).
package main

import (
	"encoding/json"
	"net/http"
	"os"
)

type message struct {
	Message string `json:"message"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, r *http.Request) {
		body, _ := json.Marshal(message{Message: "Hello, World!"})
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})

	if err := http.ListenAndServe(":"+port, mux); err != nil {
		panic(err)
	}
}
