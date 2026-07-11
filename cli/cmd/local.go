package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/spf13/cobra"
)

const (
	localInitialBackoff = 1 * time.Second
	localMaxBackoff     = 60 * time.Second
)

// Overridable for tests.
var localDialer = func(ctx context.Context, rawURL string) (*websocket.Conn, error) {
	d := websocket.DefaultDialer
	conn, _, err := d.DialContext(ctx, rawURL, nil)
	return conn, err
}

func NewLocalCommand() *cobra.Command {
	var dir string
	cmd := &cobra.Command{
		Use:   "local",
		Short: "Connect this machine to a Syrus Local Mode chat session",
		Long: `Opens a persistent reverse WebSocket tunnel from your local repository
to your Syrus backend. The chat agent can then read and write files,
run commands, and inspect git state on your machine.

Requires the local_mode feature flag to be enabled on your Syrus instance.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLocalDaemon(cmd, dir)
		},
	}
	cmd.Flags().StringVar(&dir, "dir", "", "path to the git repository (defaults to current directory)")
	return cmd
}

func runLocalDaemon(cmd *cobra.Command, dirFlag string) error {
	creds, err := loadCredentials()
	if err != nil {
		return err
	}

	startDir := dirFlag
	if startDir == "" {
		startDir, err = os.Getwd()
		if err != nil {
			return err
		}
	}

	repoRoot, err := findLocalGitRoot(cmd.Context(), startDir)
	if err != nil {
		return err
	}

	repoSlug, err := getLocalRepoSlug(cmd.Context(), repoRoot)
	if err != nil {
		return fmt.Errorf("could not determine repository: %w", err)
	}

	branch, err := getLocalBranch(cmd.Context(), repoRoot)
	if err != nil {
		return fmt.Errorf("could not determine current branch: %w", err)
	}

	wsURL, err := buildLocalCableURL(creds.URL, creds.Token)
	if err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	return runLocalWithReconnect(ctx, cmd.OutOrStdout(), wsURL, repoRoot, repoSlug, branch)
}

func findLocalGitRoot(ctx context.Context, startDir string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "-C", startDir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", errors.New("not inside a git repository — run this command from within a git repo or use --dir")
	}
	return strings.TrimSpace(string(out)), nil
}

func getLocalRepoSlug(ctx context.Context, repoRoot string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "-C", repoRoot, "remote", "get-url", "origin").Output()
	if err != nil {
		return "", errors.New("could not read git remote origin")
	}
	slug := normalizeGitRemote(strings.TrimSpace(string(out)))
	if slug == "" {
		return "", fmt.Errorf("could not derive repository slug from remote URL %q", strings.TrimSpace(string(out)))
	}
	return slug, nil
}

func getLocalBranch(ctx context.Context, repoRoot string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "-C", repoRoot, "branch", "--show-current").Output()
	if err != nil {
		return "", errors.New("could not determine current branch")
	}
	branch := strings.TrimSpace(string(out))
	if branch == "" {
		return "", errors.New("not on a branch (HEAD is detached)")
	}
	return branch, nil
}

func buildLocalCableURL(baseURL, token string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	case "http":
		parsed.Scheme = "ws"
	default:
		return "", fmt.Errorf("unsupported URL scheme %q", parsed.Scheme)
	}
	parsed.Path = "/cable"
	q := parsed.Query()
	q.Set("api_token", token)
	parsed.RawQuery = q.Encode()
	return parsed.String(), nil
}

func runLocalWithReconnect(ctx context.Context, out io.Writer, wsURL, repoRoot, repoSlug, branch string) error {
	backoff := localInitialBackoff
	for {
		err := localConnectAndServe(ctx, out, wsURL, repoRoot, repoSlug, branch)

		select {
		case <-ctx.Done():
			return nil
		default:
		}

		if err != nil {
			fmt.Fprintln(out, "Reconnecting...")
		}

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}

		next := backoff * 2
		if next > localMaxBackoff {
			next = localMaxBackoff
		}
		backoff = next
	}
}

// Action Cable wire types.
type acOutbound struct {
	Command    string `json:"command"`
	Identifier string `json:"identifier"`
	Data       string `json:"data,omitempty"`
}

type acInbound struct {
	Type       string          `json:"type,omitempty"`
	Identifier string          `json:"identifier,omitempty"`
	Message    json.RawMessage `json:"message,omitempty"`
}

type localRegisteredMsg struct {
	Type            string  `json:"type"`
	TunnelSessionID int64   `json:"tunnel_session_id"`
	ChatSessionID   *int64  `json:"chat_session_id"`
	Message         string  `json:"message,omitempty"`
}

type localToolCallMsg struct {
	Type   string          `json:"type"`
	CallID string          `json:"call_id"`
	Tool   string          `json:"tool"`
	Params json.RawMessage `json:"params"`
}

func localConnectAndServe(ctx context.Context, out io.Writer, wsURL, repoRoot, repoSlug, branch string) error {
	conn, err := localDialer(ctx, wsURL)
	if err != nil {
		return fmt.Errorf("connection failed: %w", err)
	}
	defer conn.Close()

	identJSON, err := json.Marshal(map[string]string{"channel": "LocalTunnelChannel"})
	if err != nil {
		return err
	}
	identifier := string(identJSON)

	// done is closed when localConnectAndServe is about to return, giving the
	// ctx goroutine a chance to exit before writeCh is closed.
	done := make(chan struct{})

	// Serialise all WebSocket writes through a single goroutine.
	writeCh := make(chan interface{}, 32)
	var writeWg sync.WaitGroup
	writeWg.Add(1)
	go func() {
		defer writeWg.Done()
		for msg := range writeCh {
			conn.WriteJSON(msg) //nolint:errcheck — caller checks via read errors
		}
	}()

	// Defers are LIFO: close(done) fires first so the ctx goroutine stops
	// writing to writeCh, then closeWrite drains and closes the channel.
	defer func() {
		close(writeCh)
		writeWg.Wait()
	}()
	defer close(done)

	// Handle SIGINT / SIGTERM: send a graceful disconnect before closing.
	go func() {
		select {
		case <-ctx.Done():
		case <-done:
			return
		}
		data, _ := json.Marshal(map[string]string{"type": "graceful_disconnect"})
		select {
		case writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(data)}:
		case <-done:
			return
		}
		conn.WriteControl( //nolint:errcheck
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
			time.Now().Add(2*time.Second),
		)
	}()

	// Step 1: read welcome.
	var welcome acInbound
	if err := conn.ReadJSON(&welcome); err != nil {
		return fmt.Errorf("waiting for welcome: %w", err)
	}
	if welcome.Type != "welcome" {
		return fmt.Errorf("expected welcome, got %q", welcome.Type)
	}

	// Step 2: subscribe.
	writeCh <- acOutbound{Command: "subscribe", Identifier: identifier}

	// Step 3: wait for confirm.
	var confirm acInbound
	if err := conn.ReadJSON(&confirm); err != nil {
		return fmt.Errorf("waiting for subscription confirmation: %w", err)
	}
	switch confirm.Type {
	case "confirm_subscription":
		// ok
	case "disconnect":
		return errors.New("server rejected subscription — is the local_mode feature enabled?")
	default:
		return fmt.Errorf("unexpected message type %q during subscription", confirm.Type)
	}

	// Step 4: send registration.
	regData, err := json.Marshal(map[string]string{
		"type":      "register",
		"repo_slug": repoSlug,
		"branch":    branch,
	})
	if err != nil {
		return err
	}
	writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(regData)}

	// Step 5: main loop.
	for {
		var msg acInbound
		if err := conn.ReadJSON(&msg); err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
			}
			return err
		}

		if msg.Type == "disconnect" {
			return errors.New("server closed connection")
		}

		if msg.Message == nil {
			continue
		}

		var inner map[string]json.RawMessage
		if err := json.Unmarshal(msg.Message, &inner); err != nil {
			continue
		}
		msgTypeRaw, ok := inner["type"]
		if !ok {
			continue
		}
		var msgType string
		if err := json.Unmarshal(msgTypeRaw, &msgType); err != nil {
			continue
		}

		switch msgType {
		case "registered":
			var reg localRegisteredMsg
			if err := json.Unmarshal(msg.Message, &reg); err == nil {
				if reg.ChatSessionID != nil {
					fmt.Fprintf(out, "Connected to Syrus chat session #%d\n", *reg.ChatSessionID)
				} else {
					fmt.Fprintln(out, "Connected to Syrus (no active Local Mode chat session yet)")
				}
			}

		case "tool_call":
			var call localToolCallMsg
			if err := json.Unmarshal(msg.Message, &call); err != nil {
				continue
			}
			go func(c localToolCallMsg) {
				result := executeLocalToolCall(ctx, repoRoot, c)
				payload, err := json.Marshal(map[string]any{
					"type":    "tool_result",
					"call_id": c.CallID,
					"result":  result,
				})
				if err != nil {
					return
				}
				writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(payload)}
			}(call)
		}
	}
}

// executeLocalToolCall dispatches to the right tool handler.
func executeLocalToolCall(ctx context.Context, repoRoot string, call localToolCallMsg) map[string]any {
	switch call.Tool {
	case "read_file":
		return executeLocalReadFile(repoRoot, call.Params)
	case "write_file":
		return executeLocalWriteFile(repoRoot, call.Params)
	case "list_files":
		return executeLocalListFiles(repoRoot, call.Params)
	case "run_command":
		return executeLocalRunCommand(ctx, repoRoot, call.Params)
	case "git_diff":
		return executeLocalGitDiff(ctx, repoRoot)
	case "git_diff_staged":
		return executeLocalGitDiffStaged(ctx, repoRoot)
	case "git_status":
		return executeLocalGitStatus(ctx, repoRoot)
	default:
		return map[string]any{"error": fmt.Sprintf("unknown tool %q", call.Tool)}
	}
}

// resolveLocalPath resolves a (possibly relative) path against repoRoot and
// rejects any result that escapes the repository root.
func resolveLocalPath(repoRoot, path string) (string, error) {
	abs := path
	if !filepath.IsAbs(path) {
		abs = filepath.Join(repoRoot, path)
	}
	abs = filepath.Clean(abs)

	rel, err := filepath.Rel(repoRoot, abs)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", fmt.Errorf("path %q is outside repository root", path)
	}
	return abs, nil
}

type readFileParams struct {
	Path string `json:"path"`
}

func executeLocalReadFile(repoRoot string, raw json.RawMessage) map[string]any {
	var p readFileParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return map[string]any{"error": "invalid params: " + err.Error()}
	}
	abs, err := resolveLocalPath(repoRoot, p.Path)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	content, err := os.ReadFile(abs)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"content": string(content)}
}

type writeFileParams struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

func executeLocalWriteFile(repoRoot string, raw json.RawMessage) map[string]any {
	var p writeFileParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return map[string]any{"error": "invalid params: " + err.Error()}
	}
	abs, err := resolveLocalPath(repoRoot, p.Path)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0755); err != nil {
		return map[string]any{"error": err.Error()}
	}
	if err := os.WriteFile(abs, []byte(p.Content), 0644); err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"success": true}
}

type listFilesParams struct {
	Path string `json:"path"`
}

func executeLocalListFiles(repoRoot string, raw json.RawMessage) map[string]any {
	var p listFilesParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return map[string]any{"error": "invalid params: " + err.Error()}
	}
	dir := p.Path
	if dir == "" {
		dir = "."
	}
	abs, err := resolveLocalPath(repoRoot, dir)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	files := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		files = append(files, map[string]any{"name": e.Name(), "is_dir": e.IsDir()})
	}
	return map[string]any{"files": files}
}

type runCommandParams struct {
	Command   string `json:"cmd"`
	TimeoutMS int    `json:"timeout_ms"`
}

func executeLocalRunCommand(ctx context.Context, repoRoot string, raw json.RawMessage) map[string]any {
	var p runCommandParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return map[string]any{"error": "invalid params: " + err.Error()}
	}

	cmdCtx := ctx
	var timeout time.Duration
	if p.TimeoutMS > 0 {
		timeout = time.Duration(p.TimeoutMS) * time.Millisecond
		var cancel context.CancelFunc
		cmdCtx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	shell := exec.CommandContext(cmdCtx, "sh", "-c", p.Command)
	shell.Dir = repoRoot
	// Ensure Run() returns promptly after the process is killed even when
	// grandchild processes keep inherited pipe file descriptors open.
	if timeout > 0 {
		shell.WaitDelay = timeout + 500*time.Millisecond
	}

	var stdout, stderr strings.Builder
	shell.Stdout = &stdout
	shell.Stderr = &stderr

	err := shell.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return map[string]any{"error": err.Error()}
		}
	}

	return map[string]any{
		"stdout":    stdout.String(),
		"stderr":    stderr.String(),
		"exit_code": exitCode,
	}
}

func executeLocalGitDiff(ctx context.Context, repoRoot string) map[string]any {
	out, err := exec.CommandContext(ctx, "git", "-C", repoRoot, "diff", "HEAD").Output()
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"diff": string(out)}
}

func executeLocalGitDiffStaged(ctx context.Context, repoRoot string) map[string]any {
	out, err := exec.CommandContext(ctx, "git", "-C", repoRoot, "diff", "--staged").Output()
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"diff": string(out)}
}

func executeLocalGitStatus(ctx context.Context, repoRoot string) map[string]any {
	out, err := exec.CommandContext(ctx, "git", "-C", repoRoot, "status", "--porcelain").Output()
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"status": string(out)}
}

