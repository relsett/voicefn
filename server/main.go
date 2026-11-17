// The VoiceFn website: the home, privacy policy and support pages the App Store links to.
package main

import (
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	address := env("LISTEN", ":8080")
	log.Printf("listening on %s", address)
	server := &http.Server{Addr: address, Handler: routes(NewSite(os.Getenv("SUPPORT_EMAIL"))),
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second,
		MaxHeaderBytes: 32 << 10}
	log.Fatal(server.ListenAndServe())
}

func routes(site *Site) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	mux.HandleFunc("GET /{$}", site.page("index"))
	mux.HandleFunc("GET /privacy", site.page("privacy"))
	mux.HandleFunc("GET /support", site.page("support"))
	return mux
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
