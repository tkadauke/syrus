// Package mirror keeps bare git mirrors of repositories and answers reads
// against them.
//
// A repository is a bare clone under <data>/repos/<id>.git. Syrus registers it
// with a fetch URL and a short-lived credential; the credential is held in
// memory only, never written to disk, and Syrus pushes a fresh one on every
// sync tick. After a restart the mirror still serves everything it has on disk
// and simply cannot fetch until Syrus sends a credential again.
//
// Reads are keyed by revision (a commit SHA). A commit's contents never
// change, so a mirror that has the commit answers exactly what the host would,
// however stale its refs are. Only resolving a ref depends on freshness, and
// that is bounded by the caller's max_age.
package mirror

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/gitexec"
)

// Errors a caller can tell apart. The HTTP layer maps each to a status and an
// error code the Syrus plugin translates into its content-contract errors.
var (
	ErrUnknownRepository = errors.New("unknown repository")
	ErrUnknownRevision   = errors.New("unknown revision")
	ErrNotFound          = errors.New("not found")
	ErrUnavailable       = errors.New("unavailable")
	ErrUnsupported       = errors.New("unsupported")
	ErrBadRequest        = errors.New("bad request")
	// ErrUnregistered: the repository is on disk (from before a restart) but
	// Syrus has not sent its URL and credential since, so it cannot be
	// fetched. Syrus answers by registering it and asking again.
	ErrUnregistered = errors.New("repository not registered since the mirror started")
)

var (
	idPattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	shaPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

// Config shapes a Store.
type Config struct {
	DataDir string
	// SyncInterval is how often every repository is fetched in the
	// background. Resolves younger than this never wait on a fetch.
	SyncInterval time.Duration
	FetchTimeout time.Duration
	ReadTimeout  time.Duration
	// AllowFileURLs permits file:// upstreams. Tests only: in production a
	// file URL would let Syrus point the mirror at the container's own disk.
	AllowFileURLs bool
	Git           gitexec.Runner
	Now           func() time.Time
}

// Registration is what Syrus sends for a repository.
type Registration struct {
	VCS       string     `json:"vcs"`
	URL       string     `json:"url"`
	Username  string     `json:"username,omitempty"`
	Password  string     `json:"password,omitempty"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}

// Status is a repository's state, safe to show: it never includes the
// credential.
type Status struct {
	ID            string     `json:"id"`
	URL           string     `json:"url"`
	LastFetchAt   *time.Time `json:"last_fetch_at,omitempty"`
	LastError     string     `json:"last_error,omitempty"`
	HasCredential bool       `json:"has_credential"`
	// SizeBytes is the mirror's size on disk, measured after each fetch.
	SizeBytes int64 `json:"size_bytes"`
	// LastMaintenanceAt is when `git gc --auto` last ran.
	LastMaintenanceAt *time.Time `json:"last_maintenance_at,omitempty"`
}

// Disk is the data volume's capacity and what the mirrors take up of it.
type Disk struct {
	TotalBytes  uint64 `json:"total_bytes"`
	FreeBytes   uint64 `json:"free_bytes"`
	MirrorBytes int64  `json:"mirror_bytes"`
}

// MaintenanceInterval is how often a repository gets `git gc --auto` after
// a successful fetch. --auto does nothing unless loose objects or packs
// have piled up, so this bounds disk growth at almost no cost.
const MaintenanceInterval = 24 * time.Hour

// Entry is one path in a tree.
type Entry struct {
	Path      string `json:"path"`
	Type      string `json:"type"` // file, symlink, submodule
	Size      *int64 `json:"size,omitempty"`
	ContentID string `json:"content_id"`
}

// Change is one path that differs between two revisions.
type Change struct {
	Path         string `json:"path"`
	Status       string `json:"status"` // added, modified, deleted, renamed
	PreviousPath string `json:"previous_path,omitempty"`
	// Additions and Deletions are nil for binary files.
	Additions *int `json:"additions,omitempty"`
	Deletions *int `json:"deletions,omitempty"`
	// Patch is the file's hunks (from the first @@), like GitHub's compare
	// API: only when asked for, and nil for binary files and for patches over
	// MaxPatchBytes.
	Patch *string `json:"patch,omitempty"`
}

type Ref struct {
	Name       string    `json:"name"`
	RevisionID string    `json:"revision_id"`
	ObservedAt time.Time `json:"observed_at"`
}

// Commit is one commit in a History.
type Commit struct {
	SHA        string    `json:"sha"`
	Message    string    `json:"message"`
	AuthoredAt time.Time `json:"authored_at"`
}

// History is the commits head introduced since its merge base with base
// (three-dot, like Changes), newest-first, plus that merge base's revision id.
type History struct {
	Commits     []Commit `json:"commits"`
	MergeBaseID string   `json:"merge_base_id"`
}

// MaxPatchBytes is the largest per-file patch returned; bigger ones are
// omitted, as GitHub does.
const MaxPatchBytes = 256 << 10

// Blob is a file's content at a revision.
type Blob struct {
	Bytes     []byte
	ContentID string
}

// Store holds every mirrored repository.
type Store struct {
	cfg   Config
	mu    sync.Mutex
	repos map[string]*repo
}

type repo struct {
	id  string
	dir string

	mu                sync.Mutex
	url               string
	cred              *gitexec.Credential
	expiresAt         *time.Time
	lastFetchAt       *time.Time
	lastError         string
	inflight          *fetchCall
	sizeBytes         int64
	lastMaintenanceAt *time.Time
	// registered is set once Syrus sends the repository's URL and credential
	// in this process. Repositories loaded from disk after a restart serve
	// what they have but are not fetched until then.
	registered bool
}

type fetchCall struct {
	done chan struct{}
	err  error
}

// Open loads every repository already on disk.
func Open(cfg Config) (*Store, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.SyncInterval == 0 {
		cfg.SyncInterval = 30 * time.Second
	}
	if cfg.FetchTimeout == 0 {
		cfg.FetchTimeout = 10 * time.Minute
	}
	if cfg.ReadTimeout == 0 {
		cfg.ReadTimeout = 30 * time.Second
	}
	s := &Store{cfg: cfg, repos: map[string]*repo{}}
	root := s.reposDir()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".git")
		if !ok || !entry.IsDir() || !idPattern.MatchString(id) {
			continue
		}
		r := &repo{id: id, dir: filepath.Join(root, entry.Name())}
		if res, err := s.git(context.Background(), r.dir, nil, s.cfg.ReadTimeout, "config", "--get", "remote.origin.url"); err == nil {
			r.url = strings.TrimSpace(string(res.Stdout))
		}
		r.sizeBytes = dirSize(r.dir)
		s.repos[id] = r
	}
	return s, nil
}

func (s *Store) reposDir() string { return filepath.Join(s.cfg.DataDir, "repos") }

// Register creates or updates a repository and refreshes its credential. A
// repository that has never been fetched is fetched in the background.
func (s *Store) Register(ctx context.Context, id string, reg Registration) error {
	if !idPattern.MatchString(id) {
		return fmt.Errorf("%w: invalid repository id", ErrBadRequest)
	}
	if reg.VCS != "git" {
		return fmt.Errorf("%w: this mirror serves git repositories, not %q", ErrUnsupported, reg.VCS)
	}
	if err := s.validateURL(reg.URL); err != nil {
		return err
	}

	s.mu.Lock()
	r, exists := s.repos[id]
	if !exists {
		r = &repo{id: id, dir: filepath.Join(s.reposDir(), id+".git")}
		s.repos[id] = r
	}
	s.mu.Unlock()

	r.mu.Lock()
	defer r.mu.Unlock()
	if err := s.ensureRepository(ctx, r, reg.URL); err != nil {
		return err
	}
	r.url = reg.URL
	r.cred = nil
	if reg.Username != "" || reg.Password != "" {
		r.cred = &gitexec.Credential{Username: reg.Username, Password: reg.Password}
	}
	r.expiresAt = reg.ExpiresAt
	r.registered = true
	if r.lastFetchAt == nil && r.inflight == nil {
		go func() { _ = s.fetch(context.Background(), r) }()
	}
	return nil
}

// Remove deletes a repository and its mirror.
func (s *Store) Remove(id string) error {
	s.mu.Lock()
	r, ok := s.repos[id]
	delete(s.repos, id)
	s.mu.Unlock()
	if !ok {
		return ErrUnknownRepository
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return os.RemoveAll(r.dir)
}

// List reports every repository, sorted by id.
func (s *Store) List() []Status {
	s.mu.Lock()
	repos := make([]*repo, 0, len(s.repos))
	for _, r := range s.repos {
		repos = append(repos, r)
	}
	s.mu.Unlock()

	out := make([]Status, 0, len(repos))
	for _, r := range repos {
		r.mu.Lock()
		out = append(out, Status{ID: r.id, URL: r.url, LastFetchAt: r.lastFetchAt, LastError: r.lastError, HasCredential: r.cred != nil,
			SizeBytes: r.sizeBytes, LastMaintenanceAt: r.lastMaintenanceAt})
		r.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// SyncAll fetches every repository once. Failures are recorded per repository
// and logged; one broken repository never stops the others.
func (s *Store) SyncAll(ctx context.Context) {
	s.mu.Lock()
	repos := make([]*repo, 0, len(s.repos))
	for _, r := range s.repos {
		repos = append(repos, r)
	}
	s.mu.Unlock()
	for _, r := range repos {
		if ctx.Err() != nil {
			return
		}
		r.mu.Lock()
		registered := r.registered
		r.mu.Unlock()
		if !registered {
			continue
		}
		if err := s.fetch(ctx, r); err != nil {
			log.Printf("git-mirror: sync %s: %v", r.id, err)
		}
	}
}

// Run syncs every SyncInterval until ctx is done.
func (s *Store) Run(ctx context.Context) {
	ticker := time.NewTicker(s.cfg.SyncInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.SyncAll(ctx)
		}
	}
}

// Resolve turns a branch, tag, or commit SHA into a commit SHA, fetching
// first when the mirror's view is older than maxAge. It returns the SHA and
// when the refs it was read from were fetched.
func (s *Store) Resolve(ctx context.Context, id, ref string, maxAge time.Duration) (string, time.Time, error) {
	r, err := s.get(id)
	if err != nil {
		return "", time.Time{}, err
	}
	if !validRef(ref) {
		return "", time.Time{}, fmt.Errorf("%w: invalid ref", ErrBadRequest)
	}

	if shaPattern.MatchString(ref) {
		// A commit SHA names itself; freshness does not apply. One fetch may
		// bring in a commit pushed since the last sync.
		if s.hasCommit(ctx, r, ref) {
			return ref, s.lastFetch(r), nil
		}
		if err := s.fetchIfStale(ctx, r, time.Second); errors.Is(err, ErrUnregistered) {
			return "", time.Time{}, ErrUnregistered
		} else if err == nil && s.hasCommit(ctx, r, ref) {
			return ref, s.lastFetch(r), nil
		}
		return "", time.Time{}, ErrUnknownRevision
	}

	if age, known := s.age(r); !known || age > maxAge {
		if err := s.fetch(ctx, r); err != nil {
			if errors.Is(err, ErrUnregistered) {
				return "", time.Time{}, ErrUnregistered
			}
			return "", time.Time{}, fmt.Errorf("%w: could not refresh within max_age: %v", ErrUnavailable, err)
		}
	}
	for _, candidate := range []string{"refs/heads/" + ref, "refs/tags/" + ref} {
		res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "rev-parse", "--verify", "--quiet", "--end-of-options", candidate+"^{commit}")
		if err == nil {
			return strings.TrimSpace(string(res.Stdout)), s.lastFetch(r), nil
		}
	}
	return "", time.Time{}, ErrUnknownRevision
}

// Refs lists matching tags after refreshing refs within maxAge. Git's
// version sort makes release-like tags deterministic and newest-first.
func (s *Store) Refs(ctx context.Context, id, pattern string, maxAge time.Duration) ([]Ref, error) {
	r, err := s.get(id)
	if err != nil {
		return nil, err
	}
	if pattern == "" || strings.ContainsAny(pattern, "\x00\n\r") {
		return nil, fmt.Errorf("%w: invalid pattern", ErrBadRequest)
	}
	if age, known := s.age(r); !known || age > maxAge {
		if err := s.fetch(ctx, r); err != nil {
			return nil, fmt.Errorf("%w: could not refresh within max_age: %v", ErrUnavailable, err)
		}
	}
	res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "for-each-ref", "--sort=-version:refname", "--format=%(refname:strip=2)%00%(objectname)%00%(*objectname)%00", "refs/tags/"+pattern)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	lines := strings.Split(strings.TrimSpace(string(res.Stdout)), "\n")
	refs := make([]Ref, 0, len(lines))
	observedAt := s.lastFetch(r)
	for _, line := range lines {
		fields := strings.Split(line, "\x00")
		if len(fields) < 3 {
			continue
		}
		name := fields[0]
		if name != "" {
			revisionID := fields[1]
			if fields[2] != "" {
				revisionID = fields[2]
			}
			refs = append(refs, Ref{Name: name, RevisionID: revisionID, ObservedAt: observedAt})
		}
	}
	return refs, nil
}

// Relation describes head relative to base.
func (s *Store) Relation(ctx context.Context, id, base, head string) (string, error) {
	r, err := s.revisionRepo(ctx, id, base)
	if err != nil {
		return "", err
	}
	if _, err := s.revisionRepo(ctx, id, head); err != nil {
		return "", err
	}
	if base == head {
		return "identical", nil
	}
	if _, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "merge-base", "--is-ancestor", base, head); err == nil {
		return "ahead", nil
	}
	if _, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "merge-base", "--is-ancestor", head, base); err == nil {
		return "behind", nil
	}
	return "diverged", nil
}

// History lists the commits head introduced since its merge base with base
// (three-dot, like Changes), newest-first, plus that merge base's revision
// id. Unlike GitHub's compare API, there is no cap on how many come back.
func (s *Store) History(ctx context.Context, id, base, head string) (History, error) {
	r, err := s.revisionRepo(ctx, id, base)
	if err != nil {
		return History{}, err
	}
	if _, err := s.revisionRepo(ctx, id, head); err != nil {
		return History{}, err
	}
	mergeBase, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "merge-base", base, head)
	if err != nil {
		// No merge base (unrelated histories) is the usual cause; the host may
		// still have an answer.
		return History{}, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	mergeBaseID := strings.TrimSpace(string(mergeBase.Stdout))
	res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "log", "--format=%H%x00%s%x00%cI", "--end-of-options", mergeBaseID+".."+head)
	if err != nil {
		return History{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	return History{Commits: parseCommits(string(res.Stdout)), MergeBaseID: mergeBaseID}, nil
}

// parseCommits reads `git log --format=%H%x00%s%x00%cI` output: one
// sha\x00subject\x00date record per line, newest-first (git log's default
// order). %s never contains a newline, so "\n" safely separates records.
func parseCommits(out string) []Commit {
	var commits []Commit
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\x00", 3)
		if len(fields) != 3 {
			continue
		}
		authoredAt, _ := time.Parse(time.RFC3339, fields[2])
		commits = append(commits, Commit{SHA: fields[0], Message: fields[1], AuthoredAt: authoredAt})
	}
	return commits
}

// Tree lists every file, symlink, and submodule at a commit.
func (s *Store) Tree(ctx context.Context, id, revision string) ([]Entry, error) {
	r, err := s.revisionRepo(ctx, id, revision)
	if err != nil {
		return nil, err
	}
	res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "ls-tree", "-r", "-l", "-z", "--full-tree", revision)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	var entries []Entry
	for _, record := range bytes.Split(res.Stdout, []byte{0}) {
		if len(record) == 0 {
			continue
		}
		meta, path, ok := bytes.Cut(record, []byte{'\t'})
		if !ok {
			continue
		}
		fields := strings.Fields(string(meta))
		if len(fields) != 4 {
			continue
		}
		entry := Entry{Path: string(path), ContentID: fields[2]}
		switch {
		case fields[1] == "commit":
			entry.Type = "submodule"
		case fields[1] == "blob" && fields[0] == "120000":
			entry.Type = "symlink"
		case fields[1] == "blob":
			entry.Type = "file"
		default:
			continue
		}
		if size, err := strconv.ParseInt(fields[3], 10, 64); err == nil {
			entry.Size = &size
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

// Read returns the file at path in a commit. ErrNotFound means the commit is
// known and has no file there.
func (s *Store) Read(ctx context.Context, id, revision, path string) (Blob, error) {
	if !validPath(path) {
		return Blob{}, fmt.Errorf("%w: invalid path", ErrBadRequest)
	}
	r, err := s.revisionRepo(ctx, id, revision)
	if err != nil {
		return Blob{}, err
	}
	res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "ls-tree", "-z", "--full-tree", revision, "--", path)
	if err != nil {
		return Blob{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	record := bytes.TrimRight(res.Stdout, "\x00")
	meta, listed, ok := bytes.Cut(record, []byte{'\t'})
	fields := strings.Fields(string(meta))
	if !ok || string(listed) != path || len(fields) != 3 || fields[1] != "blob" {
		return Blob{}, ErrNotFound
	}
	oid := fields[2]
	content, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "cat-file", "blob", oid)
	if err != nil {
		return Blob{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	return Blob{Bytes: content.Stdout, ContentID: oid}, nil
}

// Changes lists what head introduced since its merge base with base, the
// three-dot comparison GitHub's "Files changed" tab shows.
func (s *Store) Changes(ctx context.Context, id, base, head string, withPatch bool) ([]Change, error) {
	r, err := s.revisionRepo(ctx, id, base)
	if err != nil {
		return nil, err
	}
	if _, err := s.revisionRepo(ctx, id, head); err != nil {
		return nil, err
	}
	res, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "diff", "--name-status", "-z", "-M", "--end-of-options", base+"..."+head)
	if err != nil {
		// No merge base (unrelated histories) is the usual cause; the host may
		// still have an answer.
		return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	changes := parseNameStatus(string(res.Stdout))

	// numstat and the patch are separate passes with identical options, so
	// they list files in the same order as name-status.
	if numstat, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "diff", "--numstat", "-z", "-M", "--end-of-options", base+"..."+head); err == nil {
		applyNumstat(changes, string(numstat.Stdout))
	}
	if withPatch {
		patch, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "diff", "-M", "--no-color", "--no-ext-diff", "--end-of-options", base+"..."+head)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
		}
		applyPatches(changes, string(patch.Stdout))
	}
	return changes, nil
}

func parseNameStatus(out string) []Change {
	fields := strings.Split(strings.TrimRight(out, "\x00"), "\x00")
	var changes []Change
	for i := 0; i < len(fields) && fields[i] != ""; {
		code := fields[i]
		switch code[0] {
		case 'R':
			if i+2 >= len(fields) {
				return changes
			}
			changes = append(changes, Change{Path: fields[i+2], PreviousPath: fields[i+1], Status: "renamed"})
			i += 3
		case 'C':
			if i+2 >= len(fields) {
				return changes
			}
			changes = append(changes, Change{Path: fields[i+2], Status: "added"})
			i += 3
		default:
			if i+1 >= len(fields) {
				return changes
			}
			status := map[byte]string{'A': "added", 'D': "deleted"}[code[0]]
			if status == "" {
				status = "modified"
			}
			changes = append(changes, Change{Path: fields[i+1], Status: status})
			i += 2
		}
	}
	return changes
}

// applyNumstat fills in line counts from `git diff --numstat -z -M`: one
// "adds\tdels\tpath\0" record per file, or "adds\tdels\t\0old\0new\0"
// for a rename. Binary files report "-" and keep nil counts.
func applyNumstat(changes []Change, out string) {
	fields := strings.Split(out, "\x00")
	i := 0
	for n := 0; n < len(changes) && i < len(fields); n++ {
		parts := strings.SplitN(fields[i], "\t", 3)
		if len(parts) != 3 {
			return
		}
		if a, err := strconv.Atoi(parts[0]); err == nil {
			changes[n].Additions = &a
		}
		if d, err := strconv.Atoi(parts[1]); err == nil {
			changes[n].Deletions = &d
		}
		if parts[2] == "" {
			i += 3 // rename: old and new path follow
		} else {
			i++
		}
	}
}

// applyPatches splits a full `git diff` into per-file sections (each starts
// with "diff --git ") and keeps each file's hunks from its first "@@".
func applyPatches(changes []Change, out string) {
	sections := strings.Split(out, "\ndiff --git ")
	if len(sections) > 0 {
		sections[0] = strings.TrimPrefix(sections[0], "diff --git ")
	}
	for n := 0; n < len(changes) && n < len(sections); n++ {
		section := sections[n]
		at := strings.Index(section, "\n@@")
		if at < 0 || strings.Contains(section[:at], "\nBinary files ") {
			continue
		}
		patch := strings.TrimSuffix(section[at+1:], "\n")
		if len(patch) > MaxPatchBytes {
			continue
		}
		changes[n].Patch = &patch
	}
}

func (s *Store) get(id string) (*repo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.repos[id]
	if !ok {
		return nil, ErrUnknownRepository
	}
	return r, nil
}

// revisionRepo returns the repository when it has the commit, fetching once
// if it does not -- a commit Syrus just learned about from the host may not
// have reached the mirror yet.
func (s *Store) revisionRepo(ctx context.Context, id, revision string) (*repo, error) {
	r, err := s.get(id)
	if err != nil {
		return nil, err
	}
	if !shaPattern.MatchString(revision) {
		return nil, fmt.Errorf("%w: revision must be a full commit SHA", ErrBadRequest)
	}
	if s.hasCommit(ctx, r, revision) {
		return r, nil
	}
	if err := s.fetchIfStale(ctx, r, time.Second); errors.Is(err, ErrUnregistered) {
		return nil, ErrUnregistered
	} else if err == nil && s.hasCommit(ctx, r, revision) {
		return r, nil
	}
	return nil, ErrUnknownRevision
}

func (s *Store) hasCommit(ctx context.Context, r *repo, sha string) bool {
	_, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "cat-file", "-e", sha+"^{commit}")
	return err == nil
}

func (s *Store) age(r *repo) (time.Duration, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lastFetchAt == nil {
		return 0, false
	}
	return s.cfg.Now().Sub(*r.lastFetchAt), true
}

func (s *Store) lastFetch(r *repo) time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lastFetchAt == nil {
		return time.Time{}
	}
	return *r.lastFetchAt
}

func (s *Store) fetchIfStale(ctx context.Context, r *repo, minAge time.Duration) error {
	if age, known := s.age(r); known && age < minAge {
		return nil
	}
	return s.fetch(ctx, r)
}

// fetch updates the mirror from its upstream. Concurrent callers share one
// fetch rather than each starting their own.
func (s *Store) fetch(ctx context.Context, r *repo) error {
	r.mu.Lock()
	if call := r.inflight; call != nil {
		r.mu.Unlock()
		select {
		case <-call.done:
			return call.err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if !r.registered {
		r.mu.Unlock()
		return ErrUnregistered
	}
	call := &fetchCall{done: make(chan struct{})}
	r.inflight = call
	url, cred, expiresAt := r.url, r.cred, r.expiresAt
	r.mu.Unlock()

	call.err = s.runFetch(r, url, cred, expiresAt)
	var maintainedAt *time.Time
	var size int64
	if call.err == nil {
		maintainedAt = s.maintain(r)
		size = dirSize(r.dir)
	}

	r.mu.Lock()
	if call.err == nil {
		now := s.cfg.Now()
		r.lastFetchAt = &now
		r.lastError = ""
		r.sizeBytes = size
		if maintainedAt != nil {
			r.lastMaintenanceAt = maintainedAt
		}
	} else {
		r.lastError = call.err.Error()
	}
	r.inflight = nil
	r.mu.Unlock()
	close(call.done)
	return call.err
}

func (s *Store) runFetch(r *repo, url string, cred *gitexec.Credential, expiresAt *time.Time) error {
	if url == "" {
		return errors.New("no upstream URL registered")
	}
	if expiresAt != nil && !s.cfg.Now().Before(*expiresAt) {
		return errors.New("credential expired; waiting for Syrus to send a fresh one")
	}
	// Detached from the caller: a fetch other requests are waiting on must
	// not be cancelled because the first requester went away.
	_, err := s.git(context.Background(), r.dir, cred, s.cfg.FetchTimeout,
		"fetch", "--prune", "--no-tags", "--quiet", url,
		"+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*")
	return err
}

// maintain runs `git gc --auto` when the repository has not had it for
// MaintenanceInterval, returning when it ran (nil when it did not). A gc
// failure is logged and retried next interval; it never fails the fetch.
func (s *Store) maintain(r *repo) *time.Time {
	r.mu.Lock()
	last := r.lastMaintenanceAt
	r.mu.Unlock()
	now := s.cfg.Now()
	if last != nil && now.Sub(*last) < MaintenanceInterval {
		return nil
	}
	if _, err := s.git(context.Background(), r.dir, nil, s.cfg.FetchTimeout, "gc", "--auto", "--quiet"); err != nil {
		log.Printf("git-mirror: gc %s: %v", r.id, err)
	}
	return &now
}

// Disk reports the data volume's capacity and the mirrors' share of it.
func (s *Store) Disk() Disk {
	disk := Disk{}
	for _, status := range s.List() {
		disk.MirrorBytes += status.SizeBytes
	}
	disk.TotalBytes, disk.FreeBytes = volumeSpace(s.cfg.DataDir)
	return disk
}

func dirSize(dir string) int64 {
	var total int64
	_ = filepath.WalkDir(dir, func(_ string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		if info, err := entry.Info(); err == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

func (s *Store) ensureRepository(ctx context.Context, r *repo, url string) error {
	if _, err := os.Stat(filepath.Join(r.dir, "HEAD")); err != nil {
		if _, err := s.git(ctx, "", nil, s.cfg.ReadTimeout, "init", "--bare", "--quiet", r.dir); err != nil {
			return fmt.Errorf("%w: init: %v", ErrUnavailable, err)
		}
	}
	// The URL is kept in the repository's config so a restarted mirror knows
	// what it mirrors. The credential never is.
	if _, err := s.git(ctx, r.dir, nil, s.cfg.ReadTimeout, "config", "remote.origin.url", url); err != nil {
		return fmt.Errorf("%w: config: %v", ErrUnavailable, err)
	}
	return nil
}

func (s *Store) git(ctx context.Context, dir string, cred *gitexec.Credential, timeout time.Duration, args ...string) (gitexec.Result, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return s.cfg.Git.Run(ctx, dir, cred, args...)
}

func (s *Store) validateURL(url string) error {
	switch {
	case strings.HasPrefix(url, "https://"):
	case s.cfg.AllowFileURLs && strings.HasPrefix(url, "file://"):
	default:
		return fmt.Errorf("%w: upstream URL must be https://", ErrBadRequest)
	}
	if strings.ContainsAny(url, " \t\r\n") || strings.Contains(url, "@") {
		// Credentials belong in the registration's username/password, never
		// embedded in a URL where they would be written to the config.
		return fmt.Errorf("%w: upstream URL must not contain whitespace or credentials", ErrBadRequest)
	}
	return nil
}

// validRef accepts plain branch and tag names and commit SHAs. It rejects
// anything git would read as an option or a revision expression.
func validRef(ref string) bool {
	if ref == "" || len(ref) > 255 || strings.HasPrefix(ref, "-") || strings.HasPrefix(ref, "/") ||
		strings.HasSuffix(ref, "/") || strings.HasSuffix(ref, ".lock") || strings.Contains(ref, "..") ||
		strings.Contains(ref, "@{") {
		return false
	}
	for _, c := range ref {
		if c < 0x20 || c == 0x7f || strings.ContainsRune(" ~^:?*[\\", c) {
			return false
		}
	}
	return true
}

func validPath(path string) bool {
	if path == "" || strings.HasPrefix(path, "/") || strings.ContainsRune(path, 0) {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}
