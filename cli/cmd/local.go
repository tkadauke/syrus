package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

	localActivityPreviewRunes = 160
)

// Overridable for tests.
var localDialer = func(ctx context.Context, rawURL string) (*websocket.Conn, error) {
	d := websocket.DefaultDialer
	headers := http.Header{}
	if origin := localCableOrigin(rawURL); origin != "" {
		headers.Set("Origin", origin)
	}
	conn, response, err := d.DialContext(ctx, rawURL, headers)
	if err != nil {
		return nil, localHandshakeError(err, response)
	}
	return conn, err
}

func localCableOrigin(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}

	switch parsed.Scheme {
	case "wss":
		parsed.Scheme = "https"
	case "ws":
		parsed.Scheme = "http"
	default:
		return ""
	}
	parsed.Path = ""
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String()
}

func localHandshakeError(err error, response *http.Response) error {
	if response == nil {
		return err
	}

	var body string
	if response.Body != nil {
		defer response.Body.Close()
		bytes, readErr := io.ReadAll(io.LimitReader(response.Body, 512))
		if readErr == nil {
			body = strings.TrimSpace(string(bytes))
		}
	}

	if body == "" {
		return fmt.Errorf("%w (HTTP %d %s)", err, response.StatusCode, response.Status)
	}
	return fmt.Errorf("%w (HTTP %d %s: %s)", err, response.StatusCode, response.Status, body)
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

// localCancelToolCallMsg mirrors the "cancel_tool_call" frame
// LocalTunnelChannel#handle_cancel_broadcast transmits when the operator hits
// the composer's stop control on an in-flight `!` command (the chat shell-command cancellation feature):
// { type: "cancel_tool_call", tool_use_id: ... }.
type localCancelToolCallMsg struct {
	ToolUseID string `json:"tool_use_id"`
}

func localConnectAndServe(ctx context.Context, out io.Writer, wsURL, repoRoot, repoSlug, branch string, chatSessionID int64, tunnelToken string) error {
	conn, err := localDialer(ctx, wsURL)
	if err != nil {
		return fmt.Errorf("connection failed: %w", err)
	}
	defer conn.Close()
	activity := newLocalActivityLogger(out)

	identJSON, err := json.Marshal(map[string]any{
		"channel":         "LocalTunnelChannel",
		"chat_session_id": chatSessionID,
		"tunnel_token":    tunnelToken,
	})
	if err != nil {
		return err
	}
	identifier := string(identJSON)

	// Tracks the cancel func for each in-flight tool call, keyed by
	// tool_use_id, so a "cancel_tool_call" frame (the chat shell-command cancellation feature `!` command stop
	// control) can interrupt just that one call without affecting others or
	// the connection itself. Safe for concurrent use by the per-call
	// goroutines and the main receive loop below.
	var activeCalls sync.Map // tool_use_id (string) -> context.CancelFunc

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
			activity.connected(chatSessionID, repoSlug, branch)

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
			callCtx, cancelCall := context.WithCancel(ctx)
			activeCalls.Store(call.ToolUseID, cancelCall)
			go func(c localToolCallMsg, callCtx context.Context, cancelCall context.CancelFunc) {
				defer func() {
					activeCalls.Delete(c.ToolUseID)
					cancelCall()
				}()
				activity.toolStart(c)
				result := executeLocalToolCall(callCtx, repoRoot, c)
				activity.toolFinish(c, result)
				payload, err := json.Marshal(map[string]any{
					"type":        "tool_result",
					"tool_use_id": c.ToolUseID,
					"content":     result,
				})
				if err != nil {
					return
				}
				writeCh <- acOutbound{Command: "message", Identifier: identifier, Data: string(payload)}
			}(call, callCtx, cancelCall)

		case "cancel_tool_call":
			var cancelMsg localCancelToolCallMsg
			if err := json.Unmarshal(msg.Message, &cancelMsg); err != nil {
				continue
			}
			if cancelFn, ok := activeCalls.Load(cancelMsg.ToolUseID); ok {
				cancelFn.(context.CancelFunc)()
			}
		}
	}
}

type localActivityLogger struct {
	out io.Writer
	mu  sync.Mutex
}

func newLocalActivityLogger(out io.Writer) *localActivityLogger {
	return &localActivityLogger{out: out}
}

func (l *localActivityLogger) connected(chatSessionID int64, repoSlug, branch string) {
	l.printf("Connected to Syrus chat session #%d (%s on %s)\n", chatSessionID, repoSlug, branch)
}

func (l *localActivityLogger) toolStart(call localToolCallMsg) {
	l.printf("› %s\n", localToolCallDisplay(call))
}

func (l *localActivityLogger) toolFinish(call localToolCallMsg, result map[string]any) {
	marker := "⎿"
	summary := localToolResultSummary(call, result)
	if localToolResultFailed(result) {
		marker = "⎿ ✗"
	}
	l.printf("  %s %s\n", marker, summary)
}

func (l *localActivityLogger) printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprintf(l.out, format, args...)
}

func localToolCallDisplay(call localToolCallMsg) string {
	switch call.Tool {
	case "read_file", "write_file", "list_files":
		path := localInputString(call.Input, "path")
		if path == "" && call.Tool == "list_files" {
			path = "."
		}
		return fmt.Sprintf("%s(%s)", call.Tool, localDisplayArg(path))
	case "run_command":
		return fmt.Sprintf("run_command(%s)", localDisplayArg(localInputString(call.Input, "command")))
	case "git_status", "git_diff", "git_diff_staged":
		return call.Tool
	default:
		if call.Tool == "" {
			return "tool"
		}
		return call.Tool
	}
}

func localInputString(raw json.RawMessage, key string) string {
	var params map[string]any
	if err := json.Unmarshal(raw, &params); err != nil {
		return ""
	}
	value, _ := params[key].(string)
	return value
}

func localDisplayArg(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		value = "."
	}
	return truncateLocalActivity(value)
}

func localToolResultSummary(call localToolCallMsg, result map[string]any) string {
	if result == nil {
		return "no result"
	}
	if errText, ok := result["error"].(string); ok && strings.TrimSpace(errText) != "" {
		return truncateLocalActivity(errText)
	}

	switch call.Tool {
	case "read_file":
		if content, ok := result["content"].(string); ok {
			return fmt.Sprintf("read %d bytes", len([]byte(content)))
		}
		return "read complete"
	case "write_file":
		if result["success"] == true {
			return "wrote file"
		}
		return "write complete"
	case "list_files":
		if files, ok := result["files"].([]map[string]any); ok {
			return fmt.Sprintf("%d entries", len(files))
		}
		if files, ok := result["files"].([]any); ok {
			return fmt.Sprintf("%d entries", len(files))
		}
		return "listed files"
	case "run_command":
		return localRunCommandSummary(result)
	case "git_status":
		return localTextFieldSummary(result, "status", "clean", "status")
	case "git_diff", "git_diff_staged":
		return localTextFieldSummary(result, "diff", "no diff", "diff")
	default:
		return "complete"
	}
}

func localToolResultFailed(result map[string]any) bool {
	if result == nil {
		return true
	}
	if errText, ok := result["error"].(string); ok && strings.TrimSpace(errText) != "" {
		return true
	}
	if killed, ok := result["killed"].(bool); ok && killed {
		return true
	}
	if exitCode, ok := result["exit_code"].(int); ok && exitCode != 0 {
		return true
	}
	return false
}

func localRunCommandSummary(result map[string]any) string {
	exitCode, ok := result["exit_code"].(int)
	if !ok {
		exitCode = 0
	}
	parts := []string{fmt.Sprintf("exit %d", exitCode)}
	if killed, ok := result["killed"].(bool); ok && killed {
		parts = append(parts, "killed")
	}
	if stdout, ok := result["stdout"].(string); ok {
		if preview := localPreview(stdout); preview != "" {
			parts = append(parts, "stdout: "+preview)
		}
	}
	if stderr, ok := result["stderr"].(string); ok {
		if preview := localPreview(stderr); preview != "" {
			parts = append(parts, "stderr: "+preview)
		}
	}
	return strings.Join(parts, " ")
}

func localTextFieldSummary(result map[string]any, key, emptySummary, label string) string {
	text, _ := result[key].(string)
	preview := localPreview(text)
	if preview == "" {
		return emptySummary
	}
	return label + ": " + preview
}

func localPreview(value string) string {
	value = strings.Join(strings.Fields(value), " ")
	return truncateLocalActivity(value)
}

func truncateLocalActivity(value string) string {
	runes := []rune(value)
	if len(runes) <= localActivityPreviewRunes {
		return value
	}
	return string(runes[:localActivityPreviewRunes-1]) + "…"
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

// runCommandParams' JSON keys must match RunCommandTool's MCP input_schema
// ({ command: ... }, app/services/mcp/tools/run_command_tool.rb) exactly --
// that's the shape LocalToolDispatch.call forwards as LocalToolCall#tool_input
// and LocalTunnelChannel#dispatch_tool_call transmits verbatim as this
// message's "input" field.
type runCommandParams struct {
	Command   string `json:"command"`
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
	// Ensure Run() returns promptly after the process is killed -- by a
	// timeout above, or by a "cancel_tool_call" message (the chat shell-command cancellation feature `!` command
	// stop control, see localConnectAndServe's activeCalls) cancelling ctx --
	// even when grandchild processes keep inherited pipe file descriptors
	// open.
	if timeout > 0 {
		shell.WaitDelay = timeout + 500*time.Millisecond
	} else {
		shell.WaitDelay = 2 * time.Second
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
		} else if cmdCtx.Err() == nil {
			return map[string]any{"error": err.Error()}
		}
	}

	result := map[string]any{
		"stdout":    stdout.String(),
		"stderr":    stderr.String(),
		"exit_code": exitCode,
	}
	if cmdCtx.Err() != nil {
		result["killed"] = true
	}
	return result
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
