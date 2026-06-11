package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestListJobsSendsBearerToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/admin/jobs" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"jobs":[]}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	list, err := client.ListJobs(context.Background(), nil)
	if err != nil {
		t.Fatalf("ListJobs returned error: %v", err)
	}
	if list.Count != 0 {
		t.Fatalf("Count = %d", list.Count)
	}
}

func TestAPIErrorUsesJSONMessage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":{"code":"unauthorized","message":"Provide a valid API token."}}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "bad-token")
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.GetJob(context.Background(), "123")
	var apiErr *Error
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected *Error, got %T: %v", err, err)
	}
	if apiErr.Message != "Provide a valid API token." {
		t.Fatalf("message = %q", apiErr.Message)
	}
}

func TestNetworkErrorIsShort(t *testing.T) {
	client, err := NewClient("http://127.0.0.1:1", "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.GetJob(context.Background(), "123")
	if err == nil {
		t.Fatal("expected network error")
	}
	if !strings.Contains(err.Error(), "network error:") {
		t.Fatalf("error = %q", err.Error())
	}
}
