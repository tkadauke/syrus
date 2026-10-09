package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReviewListPrintsParseableJSONAndNormalizesJobRefs(t *testing.T) {
	cases := []struct {
		ref      string
		wantPath string
	}{
		{"JOB-7", "/api/v1/app/jobs/7/diff_review_comments"},
		{"job-7", "/api/v1/app/jobs/7/diff_review_comments"},
		{"7", "/api/v1/app/jobs/7/diff_review_comments"},
	}

	for _, tc := range cases {
		t.Run(tc.ref, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					t.Fatalf("method = %s", r.Method)
				}
				if r.URL.Path != tc.wantPath {
					t.Fatalf("path = %s", r.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(`{"job_id":7,"diff_review_version_id":3,"latest_version_id":3,"comments":[{"id":11,"job_id":7,"diff_review_version_id":3,"surface":"job_source_diff","anchor_kind":"line","path":"app/models/widget.rb","side":"right","new_line":42,"body":"Please add a spec.","state":"draft"}],"by_path":{}}`))
			}))
			defer server.Close()
			writeJobActionTestCredentials(t, server.URL)

			output := executeReviewCommand(t, []string{"review", "list", tc.ref, "--json"})
			var payload map[string]any
			if err := json.Unmarshal([]byte(output), &payload); err != nil {
				t.Fatalf("--json output is not parseable: %v\n%s", err, output)
			}
			comments := payload["comments"].([]any)
			if len(comments) != 1 {
				t.Fatalf("comments = %#v", comments)
			}
		})
	}
}

func TestReviewAddPostsDiffReviewComment(t *testing.T) {
	var payload map[string]map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		if r.URL.Path != "/api/v1/app/jobs/7/diff_review_comments" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"job_id":7,"comments":[{"id":12,"job_id":7,"diff_review_version_id":3,"path":"app/models/widget.rb","side":"right","new_line":42,"body":"Please add a spec.","state":"draft"}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := executeReviewCommand(t, []string{
		"review", "add", "JOB-7",
		"--path", "app/models/widget.rb",
		"--line", "42",
		"--body", "Please add a spec.",
		"--version", "3",
	})

	comment := payload["diff_review_comment"]
	if comment["path"] != "app/models/widget.rb" || comment["body"] != "Please add a spec." {
		t.Fatalf("payload = %#v", payload)
	}
	if comment["surface"] != "job_source_diff" || comment["state"] != "draft" || comment["anchor_kind"] != "line" {
		t.Fatalf("payload = %#v", payload)
	}
	if comment["new_line"].(float64) != 42 || comment["diff_review_version_id"].(float64) != 3 {
		t.Fatalf("payload = %#v", payload)
	}
	if output != "Added review comment 12 to JOB-7.\n" {
		t.Fatalf("output = %q", output)
	}
}

func TestReviewSubmitPostsSelectedCommentIDs(t *testing.T) {
	var payload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		if r.URL.Path != "/api/v1/app/jobs/7/diff_review_comments/submit" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"message":"submitted","workflow":{"id":21,"state":"queued"},"comments":[{"id":12},{"id":13}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := executeReviewCommand(t, []string{"review", "submit", "job-7", "--comment-id", "12", "--comment-id", "13", "--version", "3"})

	ids := payload["comment_ids"].([]any)
	if len(ids) != 2 || ids[0].(float64) != 12 || ids[1].(float64) != 13 {
		t.Fatalf("comment_ids = %#v", payload["comment_ids"])
	}
	if payload["diff_review_version_id"].(float64) != 3 {
		t.Fatalf("payload = %#v", payload)
	}
	if output != "Submitted 2 review comment(s) for JOB-7.\n" {
		t.Fatalf("output = %q", output)
	}
}

func TestReviewResolvePostsResolveEndpoint(t *testing.T) {
	var requested string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		requested = r.URL.String()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"job_id":7,"comments":[{"id":12,"state":"resolved"}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := executeReviewCommand(t, []string{"review", "resolve", "7", "12", "--version", "3"})

	if requested != "/api/v1/app/jobs/7/diff_review_comments/12/resolve?diff_review_version_id=3" {
		t.Fatalf("requested = %q", requested)
	}
	if output != "Resolved review comment 12 on JOB-7.\n" {
		t.Fatalf("output = %q", output)
	}
}

func TestReviewReplyPostsReplyBody(t *testing.T) {
	var payload map[string]string
	var requested string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		requested = r.URL.String()
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"job_id":7,"comments":[{"id":14,"parent_id":12,"body":"Fixed."}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := executeReviewCommand(t, []string{"review", "reply", "JOB-7", "12", "--body", "Fixed.", "--version", "3"})

	if requested != "/api/v1/app/jobs/7/diff_review_comments/12/reply?diff_review_version_id=3" {
		t.Fatalf("requested = %q", requested)
	}
	if payload["body"] != "Fixed." {
		t.Fatalf("payload = %#v", payload)
	}
	if output != "Replied to review comment 12 on JOB-7 with comment 14.\n" {
		t.Fatalf("output = %q", output)
	}
}

func executeReviewCommand(t *testing.T, args []string) string {
	t.Helper()

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader(""))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs(args)

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute(%v) returned error: %v", args, err)
	}

	return output.String()
}
