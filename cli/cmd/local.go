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
	var chatSessionID int64
	var tunnelToken string
	cmd := &cobra.Command{
		Use:   "local",
		Short: "Connect this machine to a Syrus Local Mode chat session",
		Long: `Opens a persistent reverse WebSocket tunnel from your local repository
to your Syrus backend. The chat agent can then read and write files,
run commands, and inspect git state on your machine.

Requires the local_mode feature flag to be enabled on your Syrus instance.
Run this with the --chat and --token values shown in the Syrus chat UI's
Local Mode banner — they pair this machine to that chat session.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if chatSessionID == 0 || tunnelToken == "" {
				return errors.New("--chat and --token are required — copy the full command from the Local Mode banner in the Syrus chat UI")
			}
			return runLocalDaemon(cmd, dir, chatSessionID, tunnelToken)
		},
	}
	cmd.Flags().StringVar(&dir, "dir", "", "path to the git repository (defaults to current directory)")
	cmd.Flags().Int64Var(&chatSessionID, "chat", 0, "Syrus chat session id (from the Local Mode pairing command)")
	cmd.Flags().StringVar(&tunnelToken, "token", "", "pairing auth token (from the Local Mode pairing command)")
	return cmd
}

func runLocalDaemon(cmd *cobra.Command, dirFlag string, chatSessionID int64, tunnelToken string) error {
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

	return runLocalWithReconnect(ctx, cmd.OutOrStdout(), wsURL, repoRoot, repoSlug, branch, chatSessionID, tunnelToken)
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

func runLocalWithReconnect(ctx context.Context, out io.Writer, wsURL, repoRoot, repoSlug, branch string, chatSessionID int64, tunnelToken string) error {
	backoff := localInitialBackoff
	for {
		err := localConnectAndServe(ctx, out, wsURL, repoRoot, repoSlug, branch, chatSessionID, tunnelToken)

		select {
		case <-ctx.Done():
			return nil
		default:
		}

		if err != nil {
			fmt.Fprintln(out, err.Error())
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

// localToolCallMsg mirrors the "tool_call" frame LocalTunnelChannel#dispatch_tool_call
// transmits: { type: "tool_call", tool_use_id: ..., tool: ..., input: ... }.
type localToolCallMsg struct {
	Type      string          `json:"type"`
	ToolUseID string          `json:"tool_use_id"`
	Tool      string          `json:"tool"`
	Input     json.RawMessage `json:"input"`
}

func localConnectAndServe(ctx context.Context, out io.Writer, wsURL, repoRoot, repoSlug, branch string, chatSessionID int64, tunnelToken string) error {
	conn, err := localDialer(ctx, wsURL)
	if err != nil {
		return fmt.Errorf("connection failed: %w", err)
	}
	defer conn.Close()

	identJSON, err := json.Marshal(map[string]any{
		"channel":         "LocalTunnelChannel",
		"chat_session_id": chatSessionID,
		"tunnel_token":    tunnelToken,
	})
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
	case "reject_subscription":
		// The real Action Cable per-channel rejection frame — sent when
		// LocalTunnelChannel#subscribed calls reject (no matching/owned
		// LocalDaemonSession for the given chat_session_id/tunnel_token, or
		// local_mode is disabled). Distinct from "disconnect", which is a
		// connection-level close, not a channel-level rejection.
		return fmt.Errorf("pairing rejected for chat session %d — check that local_mode is enabled and that --chat/--token exactly match the command shown in the Syrus chat UI (it may have expired or been regenerated)", chatSessionID)
	case "disconnect":
		return errors.New("server closed the connection — is the local_mode feature enabled?")
	default:
		return fmt.Errorf("unexpected message type %q during subscription", confirm.Type)
	}

	// Step 4: announce this machine to the daemon session. Mirrors
	// LocalTunnelChannel#receive's "connect" case, which expects "repo" and
	// "branch" fields and replies with a "connected" frame.
	connectData, err := json.Marshal(map[string]string{
		"type":   "connect",
		"repo":   repoSlug,
		"branch": branch,
	})
	if err != nil {
		return err
	}
	writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(connectData)}

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
		case "connected":
			fmt.Fprintf(out, "Connected to Syrus chat session #%d\n", chatSessionID)

		case "ping":
			// Keepalive: LocalTunnelChannel disconnects the daemon session
			// (LocalDaemonSession::HEARTBEAT_TIMEOUT, 45s) if pings go
			// unanswered, so every "ping" needs a "pong" reply.
			pongData, err := json.Marshal(map[string]string{"type": "pong"})
			if err != nil {
				continue
			}
			writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(pongData)}

		case "disconnected":
			var reason struct {
				Reason string `json:"reason"`
			}
			_ = json.Unmarshal(msg.Message, &reason)
			if reason.Reason != "" {
				return fmt.Errorf("daemon session disconnected by server (%s)", reason.Reason)
			}
			return errors.New("daemon session disconnected by server")

		case "tool_call":
			var call localToolCallMsg
			if err := json.Unmarshal(msg.Message, &call); err != nil {
				continue
			}
			go func(c localToolCallMsg) {
				result := executeLocalToolCall(ctx, repoRoot, c)
				payload, err := json.Marshal(map[string]any{
					"type":        "tool_result",
					"tool_use_id": c.ToolUseID,
					"content":     result,
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
		return executeLocalReadFile(repoRoot, call.Input)
	case "write_file":
		return executeLocalWriteFile(repoRoot, call.Input)
	case "list_files":
		return executeLocalListFiles(repoRoot, call.Input)
	case "run_command":
		return executeLocalRunCommand(ctx, repoRoot, call.Input)
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

