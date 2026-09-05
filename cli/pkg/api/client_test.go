package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

func TestListJobsSendsBearerToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs" {
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
	if !strings.HasPrefix(apiErr.Message, "Provide a valid API token.") {
		t.Fatalf("message = %q", apiErr.Message)
	}
	// A 401 must point at the fix, not just restate the server's rejection.
	if !strings.Contains(apiErr.Message, "syrus login") {
		t.Fatalf("expected 401 message to suggest 'syrus login', got %q", apiErr.Message)
	}
}

func TestAPIErrorNon401DoesNotSuggestLogin(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		w.Write([]byte(`{"error":{"code":"invalid","message":"Job is not approvable."}}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "good-token")
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.GetJob(context.Background(), "123")
	var apiErr *Error
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected *Error, got %T: %v", err, err)
	}
	if apiErr.Message != "Job is not approvable." {
		t.Fatalf("message = %q", apiErr.Message)
	}
}

func TestJobActionsPostToAppEndpoints(t *testing.T) {
	var requests []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	if err := client.ApproveJob(context.Background(), "456"); err != nil {
		t.Fatalf("ApproveJob returned error: %v", err)
	}
	if err := client.RetryJob(context.Background(), "443"); err != nil {
		t.Fatalf("RetryJob returned error: %v", err)
	}

	want := []string{
		"POST /api/v1/app/jobs/456/approve",
		"POST /api/v1/app/jobs/443/run_again",
	}
	if !slices.Equal(requests, want) {
		t.Fatalf("requests = %v, want %v", requests, want)
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
