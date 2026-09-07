package cmd

import (
	"bytes"
	"encoding/json"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLast4(t *testing.T) {
	if got := last4("secret-token"); got != "oken" {
		t.Fatalf("last4 returned %q", got)
	}
	if got := last4("abc"); got != "abc" {
		t.Fatalf("last4 short token returned %q", got)
	}
}

func TestEpicCreatePostsToCurrentRepository(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			var payload struct {
				Epic struct {
					RepositoryID int64  `json:"repository_id"`
					Title        string `json:"title"`
					Description  string `json:"description"`
				} `json:"epic"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload.Epic.RepositoryID != 3 {
				t.Fatalf("repository_id = %d", payload.Epic.RepositoryID)
			}
			if payload.Epic.Title != "Raise the forum" {
				t.Fatalf("title = %q", payload.Epic.Title)
			}
			if payload.Epic.Description != "Install tasteful columns.\nThen hold court." {
				t.Fatalf("description = %q", payload.Epic.Description)
			}
			w.Write([]byte(`{"redirect_to":"/epics/12","epic":{"id":12,"title":"Raise the forum"}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	input := strings.NewReader("Raise the forum\nInstall tasteful columns.\nThen hold court.\n\ny\n")
	output := &bytes.Buffer{}
	command.SetIn(input)
	command.SetOut(output)
	command.SetArgs([]string{"create"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !postSeen {
		t.Fatal("expected POST /api/v1/app/epics")
	}
	if got := output.String(); !strings.Contains(got, "Create epic in acme/widgets? [y/N] ") {
		t.Fatalf("output missing confirmation prompt: %q", got)
	}
	if got := output.String(); !strings.Contains(got, "Epic #12\n"+server.URL+"/epics/12") {
		t.Fatalf("output = %q", got)
	}
}

func TestEpicCreateYesSkipsConfirmation(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			w.Write([]byte(`{"redirect_to":"/epics/13","epic":{"id":13}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("Raise the forum\nInstall tasteful columns.\n\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !postSeen {
		t.Fatal("expected POST /api/v1/app/epics")
	}
	if strings.Contains(output.String(), "Create epic in acme/widgets?") {
		t.Fatalf("confirmation prompt was printed: %q", output.String())
	}
}

func TestEpicCreateStopsWhenConfirmationIsDeclined(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			w.Write([]byte(`{"epic":{"id":14}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("Raise the forum\nInstall tasteful columns.\n\nn\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if postSeen {
		t.Fatal("did not expect POST /api/v1/app/epics")
	}
	if !strings.Contains(output.String(), "Cancelled.") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestEpicCreateRequiresCurrentRepository(t *testing.T) {
	withCredentials(t, "https://syrus.example.com", "secret-token")
	withRepoSlug(t, "")

	command := NewEpicCommand()
	command.SetIn(strings.NewReader("Raise the forum\n\n"))
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"create", "--yes"})

	err := command.Execute()
	if err == nil || err.Error() != "syrus epic create requires a GitHub repository remote" {
		t.Fatalf("error = %v", err)
	}
}

func TestEpicCreateRequiresAvailableRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"repositories":[{"id":4,"slug":"other/private"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	command.SetIn(strings.NewReader("Raise the forum\n\n"))
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"create", "--yes"})

	err := command.Execute()
	if err == nil || err.Error() != "repository acme/widgets is not available to this Syrus user" {
		t.Fatalf("error = %v", err)
	}
}

func TestEpicOpenUsesConfiguredInstanceURL(t *testing.T) {
	withCredentials(t, "https://syrus.example.com/", "secret-token")
	var opened []string
	oldOpenURL := openURL
	openURL = func(target string) error {
		opened = append(opened, target)
		return nil
	}
	t.Cleanup(func() { openURL = oldOpenURL })

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"open", "12"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if len(opened) != 1 || opened[0] != "https://syrus.example.com/epics/12" {
		t.Fatalf("opened = %#v", opened)
	}
	if output.String() != "https://syrus.example.com/epics/12\n" {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobShowPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/jobs/42":
			w.Write([]byte(`{"job":{"id":42,"title":"Add avatar upload","state":"implemented"},"repository":{"slug":"acme/widgets"}}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/jobs/42/transcript":
			w.Write([]byte(`{"job_id":42,"run_id":1,"state":"succeeded","complete":true,"lines":["line one","line two"]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"show", "42", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded jobShowJSON
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Job.ID != 42 || decoded.Job.Title != "Add avatar upload" {
		t.Fatalf("decoded job = %+v", decoded.Job)
	}
	if decoded.Repository.Slug != "acme/widgets" {
		t.Fatalf("decoded repository = %+v", decoded.Repository)
	}
	if len(decoded.Transcript.Lines) != 2 {
		t.Fatalf("decoded transcript = %+v", decoded.Transcript)
	}
	if strings.Contains(output.String(), "JOB-42") {
		t.Fatalf("json output should not contain the text rendering: %q", output.String())
	}
}

func TestJobShowTextOutputUnchangedWithoutJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/jobs/42":
			w.Write([]byte(`{"job":{"id":42,"title":"Add avatar upload","state":"implemented","created_at":"2026-01-01","updated_at":"2026-01-02"},"repository":{"slug":"acme/widgets"}}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/jobs/42/transcript":
			w.Write([]byte(`{"job_id":42,"run_id":1,"state":"succeeded","complete":true,"lines":[]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"show", "42"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "JOB-42 · Add avatar upload") {
		t.Fatalf("output = %q", output.String())
	}
	if strings.HasPrefix(strings.TrimSpace(output.String()), "{") {
		t.Fatalf("expected text rendering, got JSON-shaped output: %q", output.String())
	}
}

func TestJobLogPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/jobs/42/transcript" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"job_id":42,"run_id":7,"state":"running","complete":false,"lines":["hello"]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"log", "42", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		JobID    int64    `json:"job_id"`
		Complete bool     `json:"complete"`
		Lines    []string `json:"lines"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.JobID != 42 || decoded.Complete || len(decoded.Lines) != 1 {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestJobWatchPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/jobs/42" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"job":{"id":42,"title":"Add avatar upload","state":"running"},"repository":{"slug":"acme/widgets"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"watch", "42", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Job struct {
			ID    int64  `json:"id"`
			State string `json:"state"`
		} `json:"job"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Job.ID != 42 || decoded.Job.State != "running" {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestJobDiffPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/jobs/42/diff" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"job_id":42,"pr_url":"https://github.com/acme/widgets/pull/9","diff":"","no_github_token":true}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"diff", "42", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		PRURL         string `json:"pr_url"`
		NoGithubToken bool   `json:"no_github_token"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.PRURL != "https://github.com/acme/widgets/pull/9" || !decoded.NoGithubToken {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestJobDiffTextOutputUnchangedWithoutJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"job_id":42,"pr_url":"https://github.com/acme/widgets/pull/9","diff":"","no_github_token":true}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"diff", "42"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "https://github.com/acme/widgets/pull/9\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestJobListPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/jobs" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"count":2,"jobs":[{"id":1,"title":"Fix login","state":"running"},{"id":2,"title":"Add logout","state":"queued"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Count int `json:"count"`
		Jobs  []struct {
			ID int64 `json:"id"`
		} `json:"jobs"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Count != 2 || len(decoded.Jobs) != 2 {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestJobListTextOutputUnchangedWithoutJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":1,"jobs":[{"id":1,"title":"Fix login","state":"running","repository_slug":"acme/widgets"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Fix login") || strings.HasPrefix(strings.TrimSpace(output.String()), "{") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestEpicShowPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/epics/7" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"epic":{"id":7,"number":7,"title":"Ship it","state":"open"},"jobs":[{"id":1,"title":"Part one"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewEpicCommand()
	command.SetOut(output)
	command.SetArgs([]string{"show", "7", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Epic struct {
			Title string `json:"title"`
		} `json:"epic"`
		Jobs []struct {
			ID int64 `json:"id"`
		} `json:"jobs"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Epic.Title != "Ship it" || len(decoded.Jobs) != 1 {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestEpicListPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/epics" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"count":2,"epics":[{"id":1,"title":"Alpha"},{"id":2,"title":"Beta"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "")

	output := &bytes.Buffer{}
	command := NewEpicCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Count int `json:"count"`
		Epics []struct {
			Title string `json:"title"`
		} `json:"epics"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Count != 2 || len(decoded.Epics) != 2 {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestEpicListJSONRespectsSearchQuery(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":2,"epics":[{"id":1,"title":"Alpha launch"},{"id":2,"title":"Beta launch"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "")

	output := &bytes.Buffer{}
	command := NewEpicCommand()
	command.SetOut(output)
	command.SetArgs([]string{"search", "alpha", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Count int `json:"count"`
		Epics []struct {
			Title string `json:"title"`
		} `json:"epics"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Count != 1 || len(decoded.Epics) != 1 || decoded.Epics[0].Title != "Alpha launch" {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestRepoListPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/repositories" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"repositories":[{"id":1,"slug":"acme/widgets","active_jobs_count":3}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewRepoCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Repositories []struct {
			Slug            string `json:"slug"`
			ActiveJobsCount int    `json:"active_jobs_count"`
		} `json:"repositories"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if len(decoded.Repositories) != 1 || decoded.Repositories[0].Slug != "acme/widgets" {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestRepoListTextOutputUnchangedWithoutJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"repositories":[{"id":1,"slug":"acme/widgets","active_jobs_count":3}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewRepoCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "acme/widgets") || strings.HasPrefix(strings.TrimSpace(output.String()), "{") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestWhoamiPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/app/bootstrap" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"whoami":{"email":"dev@example.com","token_suffix":"oken"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewWhoamiCommand()
	command.SetOut(output)
	command.SetArgs([]string{"--json"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	var decoded struct {
		Whoami struct {
			Email       string `json:"email"`
			TokenSuffix string `json:"token_suffix"`
		} `json:"whoami"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, output.String())
	}
	if decoded.Whoami.Email != "dev@example.com" || decoded.Whoami.TokenSuffix != "oken" {
		t.Fatalf("decoded = %+v", decoded)
	}
}

func TestWhoamiTextOutputUnchangedWithoutJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"whoami":{"email":"dev@example.com","token_suffix":"oken"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewWhoamiCommand()
	command.SetOut(output)
	command.SetArgs([]string{})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Email: dev@example.com") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobListCommandRepoFlagOverridesAutoDetection(t *testing.T) {
	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"jobs":[]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list", "--repo", "tkadauke/myapp"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(gotQuery, "repo=tkadauke%2Fmyapp") {
		t.Fatalf("query = %q", gotQuery)
	}
}

func TestJobSearchCommandRepoFlagOverridesAutoDetection(t *testing.T) {
	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"jobs":[]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	output := &bytes.Buffer{}
	command := NewJobCommand()
	command.SetOut(output)
	command.SetArgs([]string{"search", "login", "--repo", "tkadauke/myapp"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(gotQuery, "repo=tkadauke%2Fmyapp") {
		t.Fatalf("query = %q", gotQuery)
	}
}

func TestEpicListCommandRepoFlagOverridesAutoDetection(t *testing.T) {
	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"epics":[]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	output := &bytes.Buffer{}
	command := NewEpicCommand()
	command.SetOut(output)
	command.SetArgs([]string{"list", "--repo", "tkadauke/myapp"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(gotQuery, "repo=tkadauke%2Fmyapp") {
		t.Fatalf("query = %q", gotQuery)
	}
}

func TestEpicSearchCommandRepoFlagOverridesAutoDetection(t *testing.T) {
	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"epics":[]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	output := &bytes.Buffer{}
	command := NewEpicCommand()
	command.SetOut(output)
	command.SetArgs([]string{"search", "launch", "--repo", "tkadauke/myapp"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(gotQuery, "repo=tkadauke%2Fmyapp") {
		t.Fatalf("query = %q", gotQuery)
	}
}

func withCredentials(t *testing.T, url string, token string) {
	t.Helper()
	cliplugintest.WithCredentials(t, url, token)
}

func withRepoSlug(t *testing.T, slug string) {
	t.Helper()
	cliplugintest.WithRepoSlug(t, slug)
}
