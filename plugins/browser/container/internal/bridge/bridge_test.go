package bridge

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	t.Run("reports ok when the child is alive", func(t *testing.T) {
		handler, err := New("http://127.0.0.1:0", func() error { return nil })
		if err != nil {
			t.Fatalf("New: %v", err)
		}

		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, HealthPath, nil))

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
		}
		if body := rec.Body.String(); !strings.Contains(body, `"status":"ok"`) {
			t.Fatalf("body = %q, want it to report ok", body)
		}
	})

	t.Run("reports unavailable when the child cannot be reached", func(t *testing.T) {
		handler, err := New("http://127.0.0.1:0", func() error { return errors.New("connection refused") })
		if err != nil {
			t.Fatalf("New: %v", err)
		}

		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, HealthPath, nil))

		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
		}
		if body := rec.Body.String(); !strings.Contains(body, "connection refused") {
			t.Fatalf("body = %q, want it to explain why", body)
		}
	})

	t.Run("never proxies the health path to the child", func(t *testing.T) {
		childCalled := false
		child := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			childCalled = true
			w.WriteHeader(http.StatusNotFound)
		}))
		defer child.Close()

		handler, err := New(child.URL, func() error { return nil })
		if err != nil {
			t.Fatalf("New: %v", err)
		}

		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, HealthPath, nil))

		if childCalled {
			t.Fatal("expected the health check to be answered locally, not forwarded to the child")
		}
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
		}
	})
}

func TestProxiesEverythingElseToTheChild(t *testing.T) {
	var gotMethod, gotPath, gotBody, gotSessionHeader string
	child := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotSessionHeader = r.Header.Get("Mcp-Session-Id")
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer child.Close()

	handler, err := New(child.URL, func() error { return nil })
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(`{"jsonrpc":"2.0"}`))
	req.Header.Set("Mcp-Session-Id", "abc123")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if gotMethod != http.MethodPost {
		t.Errorf("child saw method %q, want POST", gotMethod)
	}
	if gotPath != "/mcp" {
		t.Errorf("child saw path %q, want /mcp", gotPath)
	}
	if gotBody != `{"jsonrpc":"2.0"}` {
		t.Errorf("child saw body %q", gotBody)
	}
	if gotSessionHeader != "abc123" {
		t.Errorf("child saw Mcp-Session-Id %q, want it forwarded", gotSessionHeader)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if body := rec.Body.String(); body != `{"ok":true}` {
		t.Errorf("body = %q, want the child's response forwarded verbatim", body)
	}
}

func TestNewRejectsAnUnparseableChildURL(t *testing.T) {
	if _, err := New(":not a url:", func() error { return nil }); err == nil {
		t.Fatal("expected an error for an unparseable child URL")
	}
}
