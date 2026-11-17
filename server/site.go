package main

import (
	"bytes"
	"embed"
	"html/template"
	"log"
	"net/http"
)

//go:embed site/*.html
var siteFiles embed.FS

// Site serves the public pages the App Store links to: home, privacy policy and support.
type Site struct {
	pages map[string]*template.Template
	email string
}

func NewSite(email string) *Site {
	site := &Site{pages: map[string]*template.Template{}, email: email}
	for _, name := range []string{"index", "privacy", "support"} {
		site.pages[name] = template.Must(template.ParseFS(siteFiles, "site/layout.html", "site/"+name+".html"))
	}
	return site
}

var pageTitles = map[string]string{"index": "VoiceFn", "privacy": "VoiceFn Privacy Policy", "support": "VoiceFn Support"}

func (s *Site) page(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		var body bytes.Buffer
		if err := s.pages[name].ExecuteTemplate(&body, "layout", map[string]string{"Title": pageTitles[name], "Email": s.email}); err != nil {
			log.Printf("render %s: %v", name, err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/html; charset=utf-8")
		h.Set("Cache-Control", "public, max-age=300")
		// The pages are self-contained: one inline stylesheet, no scripts, images or frames.
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		w.Write(body.Bytes())
	}
}
