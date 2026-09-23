package mirror

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// upstream is a real git repository the mirror fetches from over file://.
type upstream struct {
	t   *testing.T
	dir string
}

func newUpstream(t *testing.T) *upstream {
	t.Helper()
	u := &upstream{t: t, dir: t.TempDir()}
	u.git("init", "--quiet", "--initial-branch=main")
	u.git("config", "user.email", "test@example.test")
	u.git("config", "user.name", "Test")
	return u
}

func (u *upstream) git(args ...string) string {
	u.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = u.dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		u.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func (u *upstream) commit(files map[string]string, message string) string {
	u.t.Helper()
	for path, content := range files {
		full := filepath.Join(u.dir, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			u.t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			u.t.Fatal(err)
		}
	}
	u.git("add", "-A")
	u.git("commit", "--quiet", "-m", message)
	return u.git("rev-parse", "HEAD")
}

func (u *upstream) url() string { return "file://" + u.dir }

type clock struct{ now time.Time }

func (c *clock) Now() time.Time { return c.now }

func newStore(t *testing.T, c *clock) *Store {
	t.Helper()
	cfg := Config{DataDir: t.TempDir(), AllowFileURLs: true}
	if c != nil {
		cfg.Now = c.Now
	}
	s, err := Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// register adds the repository and waits for its first fetch.
func register(t *testing.T, s *Store, id string, u *upstream) {
	t.Helper()
	if err := s.Register(context.Background(), id, Registration{VCS: "git", URL: u.url()}); err != nil {
		t.Fatal(err)
	}
	r, _ := s.get(id)
	if err := s.fetch(context.Background(), r); err != nil {
		t.Fatal(err)
	}
}

func TestResolveTreeAndRead(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{".syrus.yml": "grade: []\n", "apps/web/.syrus.yml": "project:\n  id: web\n"}, "first")
	u.git("tag", "v1")
	s := newStore(t, nil)
	register(t, s, "42", u)
	ctx := context.Background()

	for _, ref := range []string{"main", "v1", sha} {
		got, _, err := s.Resolve(ctx, "42", ref, time.Minute)
		if err != nil || got != sha {
			t.Fatalf("resolve %q = %q, %v; want %q", ref, got, err, sha)
		}
	}

	entries, err := s.Tree(ctx, "42", sha)
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{}
	for _, e := range entries {
		paths = append(paths, e.Path+":"+e.Type)
		if e.ContentID == "" || e.Size == nil {
			t.Fatalf("entry %+v lacks content id or size", e)
		}
	}
	if strings.Join(paths, ",") != ".syrus.yml:file,apps/web/.syrus.yml:file" {
		t.Fatalf("unexpected tree %v", paths)
	}

	blob, err := s.Read(ctx, "42", sha, "apps/web/.syrus.yml")
	if err != nil || string(blob.Bytes) != "project:\n  id: web\n" || blob.ContentID == "" {
		t.Fatalf("read = %q, %v", blob.Bytes, err)
	}
}

func TestRefsAndRevisionRelation(t *testing.T) {
	u := newUpstream(t)
	base := u.commit(map[string]string{"a.txt": "1"}, "base")
	u.git("tag", "deploy-1")
	head := u.commit(map[string]string{"a.txt": "2"}, "head")
	u.git("tag", "-a", "deploy-2", "-m", "release")
	s := newStore(t, nil)
	register(t, s, "42", u)

	refs, err := s.Refs(context.Background(), "42", "deploy-*", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if len(refs) != 2 || refs[0].Name != "deploy-2" || refs[0].RevisionID != head || refs[1].RevisionID != base {
		t.Fatalf("unexpected refs: %+v", refs)
	}
	if relation, err := s.Relation(context.Background(), "42", base, head); err != nil || relation != "ahead" {
		t.Fatalf("relation = %q, %v; want ahead", relation, err)
	}
	if relation, err := s.Relation(context.Background(), "42", head, base); err != nil || relation != "behind" {
		t.Fatalf("reverse relation = %q, %v; want behind", relation, err)
	}
}

// The distinction the whole content contract rests on: a missing file in a
// known commit is final; a commit the mirror has never seen is not.
func TestMissingFileIsNotFoundButUnknownCommitIsUnknownRevision(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{"a.txt": "a"}, "first")
	s := newStore(t, nil)
	register(t, s, "42", u)
	ctx := context.Background()

	if _, err := s.Read(ctx, "42", sha, "missing.txt"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing file: got %v, want ErrNotFound", err)
	}
	if _, err := s.Read(ctx, "42", sha, "a.txt/"); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("bad path: got %v, want ErrBadRequest", err)
	}
	unknown := strings.Repeat("0", 40)
	if _, err := s.Read(ctx, "42", unknown, "a.txt"); !errors.Is(err, ErrUnknownRevision) {
		t.Fatalf("unknown commit: got %v, want ErrUnknownRevision", err)
	}
	if _, _, err := s.Resolve(ctx, "42", "no-such-branch", time.Minute); !errors.Is(err, ErrUnknownRevision) {
		t.Fatalf("unknown branch: got %v, want ErrUnknownRevision", err)
	}
	if _, err := s.Tree(ctx, "nope", sha); !errors.Is(err, ErrUnknownRepository) {
		t.Fatalf("unknown repo: got %v, want ErrUnknownRepository", err)
	}
}

func TestReadingADirectoryIsNotFound(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{"dir/a.txt": "a"}, "first")
	s := newStore(t, nil)
	register(t, s, "42", u)

	if _, err := s.Read(context.Background(), "42", sha, "dir"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

// A commit pushed after the last sync is fetched on demand rather than
// reported unknown.
func TestUnseenCommitIsFetchedOnDemand(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"a.txt": "1"}, "first")
	c := &clock{now: time.Now()}
	s := newStore(t, c)
	register(t, s, "42", u)

	newer := u.commit(map[string]string{"a.txt": "2"}, "second")
	c.now = c.now.Add(5 * time.Second)

	blob, err := s.Read(context.Background(), "42", newer, "a.txt")
	if err != nil || string(blob.Bytes) != "2" {
		t.Fatalf("read = %q, %v", blob.Bytes, err)
	}
}

func TestResolveRespectsMaxAge(t *testing.T) {
	u := newUpstream(t)
	first := u.commit(map[string]string{"a.txt": "1"}, "first")
	c := &clock{now: time.Now()}
	s := newStore(t, c)
	register(t, s, "42", u)
	second := u.commit(map[string]string{"a.txt": "2"}, "second")
	ctx := context.Background()

	c.now = c.now.Add(30 * time.Second)
	if got, _, _ := s.Resolve(ctx, "42", "main", time.Minute); got != first {
		t.Fatalf("within max_age: got %s, want the mirrored %s", got, first)
	}
	if got, _, _ := s.Resolve(ctx, "42", "main", 10*time.Second); got != second {
		t.Fatalf("past max_age: got %s, want a fresh %s", got, second)
	}
}

func TestStaleResolveIsUnavailableWhenTheUpstreamIsUnreachable(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"a.txt": "1"}, "first")
	c := &clock{now: time.Now()}
	s := newStore(t, c)
	register(t, s, "42", u)
	if err := os.RemoveAll(u.dir); err != nil {
		t.Fatal(err)
	}
	c.now = c.now.Add(2 * time.Minute)

	if _, _, err := s.Resolve(context.Background(), "42", "main", time.Minute); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	// Maximum staleness tolerated: the mirror still answers from what it has.
	if _, _, err := s.Resolve(context.Background(), "42", "main", time.Hour); err != nil {
		t.Fatalf("got %v, want the mirrored answer", err)
	}
}

func TestExpiredCredentialStopsFetching(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"a.txt": "1"}, "first")
	c := &clock{now: time.Now()}
	s := newStore(t, c)
	past := c.now.Add(-time.Minute)
	if err := s.Register(context.Background(), "42", Registration{VCS: "git", URL: u.url(), Password: "x", ExpiresAt: &past}); err != nil {
		t.Fatal(err)
	}
	r, _ := s.get("42")
	if err := s.fetch(context.Background(), r); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("got %v, want an expired-credential error", err)
	}
}

func TestChangesAreThreeDot(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"keep.txt": "k", "old.txt": strings.Repeat("rename me\n", 20), "gone.txt": "g"}, "base")
	u.git("checkout", "--quiet", "-b", "feature")
	u.git("mv", "old.txt", "new.txt")
	u.git("rm", "--quiet", "gone.txt")
	head := u.commit(map[string]string{"added.txt": "a", "keep.txt": "changed"}, "feature work")
	u.git("checkout", "--quiet", "main")
	// main moves on after the branch point; three-dot must not report it.
	base := u.commit(map[string]string{"main-only.txt": "m"}, "main moves")
	s := newStore(t, nil)
	register(t, s, "42", u)

	changes, err := s.Changes(context.Background(), "42", base, head, false)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, c := range changes {
		got[c.Path] = c.Status + "<" + c.PreviousPath
	}
	want := map[string]string{"added.txt": "added<", "keep.txt": "modified<", "gone.txt": "deleted<", "new.txt": "renamed<old.txt"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for path, status := range want {
		if got[path] != status {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestHistoryListsCommitsSinceMergeBaseNewestFirst(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"keep.txt": "k"}, "base")
	mergeBase := u.git("rev-parse", "HEAD")
	u.git("checkout", "--quiet", "-b", "feature")
	first := u.commit(map[string]string{"a.txt": "1"}, "first commit")
	second := u.commit(map[string]string{"a.txt": "2"}, "second commit")
	u.git("checkout", "--quiet", "main")
	// main moves on after the branch point; three-dot must not report it,
	// and must not treat main's new tip as the merge base either.
	base := u.commit(map[string]string{"main-only.txt": "m"}, "main moves")
	s := newStore(t, nil)
	register(t, s, "42", u)

	history, err := s.History(context.Background(), "42", base, second)
	if err != nil {
		t.Fatal(err)
	}
	if history.MergeBaseID != mergeBase {
		t.Fatalf("merge base = %s, want %s", history.MergeBaseID, mergeBase)
	}
	if len(history.Commits) != 2 || history.Commits[0].SHA != second || history.Commits[1].SHA != first {
		t.Fatalf("unexpected commits: %+v", history.Commits)
	}
	if history.Commits[0].Message != "second commit" || history.Commits[1].Message != "first commit" {
		t.Fatalf("unexpected messages: %+v", history.Commits)
	}
	for _, c := range history.Commits {
		if c.AuthoredAt.IsZero() {
			t.Fatalf("commit %s has no authored_at: %+v", c.SHA, c)
		}
	}
}

func TestHistoryIsEmptyWhenHeadIsTheMergeBase(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{"a.txt": "1"}, "only commit")
	s := newStore(t, nil)
	register(t, s, "42", u)

	history, err := s.History(context.Background(), "42", sha, sha)
	if err != nil {
		t.Fatal(err)
	}
	if history.MergeBaseID != sha || len(history.Commits) != 0 {
		t.Fatalf("unexpected history: %+v", history)
	}
}

func TestReopenKeepsRepositoriesButNotCredentials(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{"a.txt": "1"}, "first")
	dir := t.TempDir()
	s, _ := Open(Config{DataDir: dir, AllowFileURLs: true})
	if err := s.Register(context.Background(), "42", Registration{VCS: "git", URL: u.url(), Username: "u", Password: "p"}); err != nil {
		t.Fatal(err)
	}
	r, _ := s.get("42")
	_ = s.fetch(context.Background(), r)

	config, _ := os.ReadFile(filepath.Join(dir, "repos", "42.git", "config"))
	if strings.Contains(string(config), "p") && strings.Contains(string(config), "Authorization") {
		t.Fatalf("credential written to config:\n%s", config)
	}

	reopened, err := Open(Config{DataDir: dir, AllowFileURLs: true})
	if err != nil {
		t.Fatal(err)
	}
	status := reopened.List()
	if len(status) != 1 || status[0].URL != u.url() || status[0].HasCredential {
		t.Fatalf("unexpected status after reopen: %+v", status)
	}
	if blob, err := reopened.Read(context.Background(), "42", sha, "a.txt"); err != nil || string(blob.Bytes) != "1" {
		t.Fatalf("read after reopen = %q, %v", blob.Bytes, err)
	}
}

func TestRegisterRejectsUnsafeInput(t *testing.T) {
	s, _ := Open(Config{DataDir: t.TempDir()})
	ctx := context.Background()
	cases := map[string]Registration{
		"file url in production": {VCS: "git", URL: "file:///etc"},
		"credential in url":      {VCS: "git", URL: "https://user:token@github.com/a/b.git"},
		"plain http":             {VCS: "git", URL: "http://github.com/a/b.git"},
	}
	for name, reg := range cases {
		if err := s.Register(ctx, "42", reg); !errors.Is(err, ErrBadRequest) {
			t.Errorf("%s: got %v, want ErrBadRequest", name, err)
		}
	}
	if err := s.Register(ctx, "42", Registration{VCS: "hg", URL: "https://example.test/r"}); !errors.Is(err, ErrUnsupported) {
		t.Errorf("hg: got %v, want ErrUnsupported", err)
	}
	if err := s.Register(ctx, "../etc", Registration{VCS: "git", URL: "https://example.test/r.git"}); !errors.Is(err, ErrBadRequest) {
		t.Errorf("traversal id: got %v, want ErrBadRequest", err)
	}
}

func TestRefValidationRejectsOptionsAndExpressions(t *testing.T) {
	for _, ref := range []string{"-c", "--upload-pack=x", "main~1", "main^", "a..b", "HEAD@{1}", "a b", "x:y"} {
		if validRef(ref) {
			t.Errorf("accepted %q", ref)
		}
	}
	for _, ref := range []string{"main", "release/1.2", "syrus/issue-42", strings.Repeat("a", 40)} {
		if !validRef(ref) {
			t.Errorf("rejected %q", ref)
		}
	}
}

// After a restart the mirror still serves what is on disk, but has no
// credential: it must neither fetch (every sync would fail against a private
// repository) nor pretend its refs are fresh.
func TestAfterARestartRepositoriesServeFromDiskButWaitForRegistration(t *testing.T) {
	u := newUpstream(t)
	sha := u.commit(map[string]string{"a.txt": "1"}, "first")
	dir := t.TempDir()
	s, _ := Open(Config{DataDir: dir, AllowFileURLs: true})
	register(t, s, "42", u)

	restarted, _ := Open(Config{DataDir: dir, AllowFileURLs: true})
	ctx := context.Background()

	if blob, err := restarted.Read(ctx, "42", sha, "a.txt"); err != nil || string(blob.Bytes) != "1" {
		t.Fatalf("read from disk = %q, %v", blob.Bytes, err)
	}
	if _, _, err := restarted.Resolve(ctx, "42", "main", time.Minute); !errors.Is(err, ErrUnregistered) {
		t.Fatalf("resolve before registration: %v, want ErrUnregistered", err)
	}
	if _, err := restarted.Read(ctx, "42", strings.Repeat("1", 40), "a.txt"); !errors.Is(err, ErrUnregistered) {
		t.Fatalf("unknown commit before registration: %v, want ErrUnregistered", err)
	}
	restarted.SyncAll(ctx)
	if status := restarted.List()[0]; status.LastError != "" {
		t.Fatalf("background sync tried to fetch an unregistered repository: %q", status.LastError)
	}

	register(t, restarted, "42", u)
	if got, _, err := restarted.Resolve(ctx, "42", "main", time.Minute); err != nil || got != sha {
		t.Fatalf("resolve after registration = %s, %v", got, err)
	}
}

func TestChangesCarryLineCountsAndPatches(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"a.txt": "one\ntwo\n", "old.txt": strings.Repeat("rename me\n", 20), "logo.bin": "\x00\x01"}, "base")
	base := u.git("rev-parse", "HEAD")
	u.git("mv", "old.txt", "new.txt")
	head := u.commit(map[string]string{"a.txt": "one\n2\nthree\n", "logo.bin": "\x00\x02"}, "change")
	s := newStore(t, nil)
	register(t, s, "42", u)

	withoutPatch, err := s.Changes(context.Background(), "42", base, head, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range withoutPatch {
		if c.Patch != nil {
			t.Fatalf("%s: patch returned without being asked for", c.Path)
		}
	}

	changes, err := s.Changes(context.Background(), "42", base, head, true)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]Change{}
	for _, c := range changes {
		byPath[c.Path] = c
	}
	text := byPath["a.txt"]
	if text.Additions == nil || *text.Additions != 2 || text.Deletions == nil || *text.Deletions != 1 {
		t.Fatalf("a.txt counts: %+v", text)
	}
	if text.Patch == nil || !strings.HasPrefix(*text.Patch, "@@ ") || !strings.Contains(*text.Patch, "+three") {
		t.Fatalf("a.txt patch: %v", text.Patch)
	}
	if renamed := byPath["new.txt"]; renamed.Status != "renamed" || renamed.Additions == nil || *renamed.Additions != 0 {
		t.Fatalf("rename: %+v", renamed)
	}
	if binary := byPath["logo.bin"]; binary.Additions != nil || binary.Patch != nil {
		t.Fatalf("binary file should have no counts or patch: %+v", binary)
	}
}

func TestFetchMeasuresSizeAndRunsMaintenanceDaily(t *testing.T) {
	u := newUpstream(t)
	u.commit(map[string]string{"a.txt": strings.Repeat("x", 10_000)}, "first")
	c := &clock{now: time.Now()}
	s := newStore(t, c)
	register(t, s, "42", u)

	status := s.List()[0]
	if status.SizeBytes <= 0 || status.LastMaintenanceAt == nil {
		t.Fatalf("after first fetch: %+v", status)
	}
	first := *status.LastMaintenanceAt

	c.now = c.now.Add(time.Hour)
	r, _ := s.get("42")
	if err := s.fetch(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	if got := *s.List()[0].LastMaintenanceAt; !got.Equal(first) {
		t.Fatalf("maintenance ran again within the interval: %v", got)
	}

	c.now = c.now.Add(MaintenanceInterval)
	if err := s.fetch(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	if got := *s.List()[0].LastMaintenanceAt; !got.After(first) {
		t.Fatalf("maintenance did not run after the interval: %v", got)
	}

	disk := s.Disk()
	if disk.TotalBytes == 0 || disk.FreeBytes == 0 || disk.MirrorBytes != s.List()[0].SizeBytes {
		t.Fatalf("disk = %+v", disk)
	}
}
