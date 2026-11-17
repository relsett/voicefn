package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPages(t *testing.T) {
	handler := routes(NewSite("help@example.com"))
	for path, want := range map[string]string{"/": "Press fn", "/privacy": "never leave", "/support": "help@example.com", "/healthz": "ok"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK || !strings.Contains(recorder.Body.String(), want) {
			t.Errorf("%s: %d, missing %q", path, recorder.Code, want)
		}
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/privacy", nil))
	if csp := recorder.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Errorf("CSP: %q", csp)
	}
	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/nope", nil))
	if recorder.Code != http.StatusNotFound {
		t.Errorf("/nope: %d", recorder.Code)
	}
}
