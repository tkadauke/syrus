package cmd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

var wsUpgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

// newLocalWSServer starts a test WebSocket server. handler receives the
// upgraded connection and can exchange messages with the client.
func newLocalWSServer(t *testing.T, handler func(*websocket.Conn)) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := wsUpgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		handler(conn)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// wsURL converts an httptest server URL to ws://.
func wsURL(t *testing.T, srv *httptest.Server) string {
	t.Helper()
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	u.Scheme = "ws"
	u.Path = "/cable"
	return u.String()
}

// ---------------------------------------------------------------------------
// buildLocalCableURL
// ---------------------------------------------------------------------------

func TestBuildLocalCableURLConvertsHTTPtoWS(t *testing.T) {
	got, err := buildLocalCableURL("http://syrus.example.com", "tok-abc")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(got, "ws://") {
		t.Fatalf("expected ws:// scheme, got %q", got)
	}
	if !strings.Contains(got, "api_token=tok-abc") {
		t.Fatalf("expected api_token in URL, got %q", got)
	}
	if !strings.Contains(got, "/cable") {
		t.Fatalf("expected /cable path, got %q", got)
	}
}

func TestBuildLocalCableURLConvertsHTTPStoWSS(t *testing.T) {
	got, err := buildLocalCableURL("https://syrus.example.com", "tok-abc")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(got, "wss://") {
		t.Fatalf("expected wss:// scheme, got %q", got)
	}
}

func TestBuildLocalCableURLRejectsUnknownScheme(t *testing.T) {
	_, err := buildLocalCableURL("ftp://syrus.example.com", "tok")
	if err == nil {
		t.Fatal("expected error for unsupported scheme")
	}
}

// ---------------------------------------------------------------------------
// resolveLocalPath (boundary enforcement)
// ---------------------------------------------------------------------------

func TestResolveLocalPathAllowsRelativePaths(t *testing.T) {
	root := t.TempDir()
	got, err := resolveLocalPath(root, "src/main.go")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != filepath.Join(root, "src/main.go") {
		t.Fatalf("got %q", got)
	}
}

func TestResolveLocalPathAllowsRepoRoot(t *testing.T) {
	root := t.TempDir()
	got, err := resolveLocalPath(root, ".")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != root {
		t.Fatalf("got %q, want %q", got, root)
	}
}

func TestResolveLocalPathRejectsDotDotEscape(t *testing.T) {
	root := t.TempDir()
	_, err := resolveLocalPath(root, "../etc/passwd")
	if err == nil {
		t.Fatal("expected error for path escaping repo root")
	}
}

func TestResolveLocalPathRejectsAbsolutePathOutsideRoot(t *testing.T) {
	root := t.TempDir()
	_, err := resolveLocalPath(root, "/etc/passwd")
	if err == nil {
		t.Fatal("expected error for absolute path outside repo root")
	}
}

func TestResolveLocalPathAllowsAbsolutePathInsideRoot(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "sub", "file.txt")
	got, err := resolveLocalPath(root, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != target {
		t.Fatalf("got %q, want %q", got, target)
	}
}

// ---------------------------------------------------------------------------
// executeLocalReadFile
// ---------------------------------------------------------------------------

func TestExecuteLocalReadFileReturnsContent(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("world"), 0600); err != nil {
		t.Fatal(err)
	}

	params, _ := json.Marshal(readFileParams{Path: "hello.txt"})
	result := executeLocalReadFile(root, params)

	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	if result["content"] != "world" {
		t.Fatalf("content = %q", result["content"])
	}
}

func TestExecuteLocalReadFileRejectsBoundaryEscape(t *testing.T) {
	root := t.TempDir()
	params, _ := json.Marshal(readFileParams{Path: "../secret"})
	result := executeLocalReadFile(root, params)
	if result["error"] == nil {
		t.Fatal("expected error for boundary escape")
	}
}

// ---------------------------------------------------------------------------
// executeLocalWriteFile
// ---------------------------------------------------------------------------

func TestExecuteLocalWriteFileCreatesFile(t *testing.T) {
	root := t.TempDir()
	params, _ := json.Marshal(writeFileParams{Path: "sub/new.txt", Content: "hello"})
	result := executeLocalWriteFile(root, params)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	if result["success"] != true {
		t.Fatalf("expected success=true")
	}
	got, err := os.ReadFile(filepath.Join(root, "sub/new.txt"))
	if err != nil {
		t.Fatalf("file not created: %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("content = %q", got)
	}
}

func TestExecuteLocalWriteFileRejectsBoundaryEscape(t *testing.T) {
	root := t.TempDir()
	params, _ := json.Marshal(writeFileParams{Path: "../../outside.txt", Content: "x"})
	result := executeLocalWriteFile(root, params)
	if result["error"] == nil {
		t.Fatal("expected error for boundary escape")
	}
}

// ---------------------------------------------------------------------------
// executeLocalListFiles
// ---------------------------------------------------------------------------

func TestExecuteLocalListFilesReturnsEntries(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte(""), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "subdir"), 0755); err != nil {
		t.Fatal(err)
	}

	params, _ := json.Marshal(listFilesParams{Path: "."})
	result := executeLocalListFiles(root, params)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	files, ok := result["files"].([]map[string]any)
	if !ok {
		t.Fatalf("files is not []map[string]any: %T", result["files"])
	}
	names := map[string]bool{}
	for _, f := range files {
		names[f["name"].(string)] = f["is_dir"].(bool)
	}
	if !names["subdir"] {
		t.Fatal("expected subdir to be a directory")
	}
	if names["a.txt"] {
		t.Fatal("expected a.txt to not be a directory")
	}
}

func TestExecuteLocalListFilesDefaultsToRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "readme.md"), []byte(""), 0600); err != nil {
		t.Fatal(err)
	}

	params, _ := json.Marshal(listFilesParams{})
	result := executeLocalListFiles(root, params)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
}

// ---------------------------------------------------------------------------
// executeLocalRunCommand
// ---------------------------------------------------------------------------

func TestExecuteLocalRunCommandCapturesStdout(t *testing.T) {
	root := t.TempDir()
	params, _ := json.Marshal(runCommandParams{Command: "echo hello"})
	result := executeLocalRunCommand(context.Background(), root, params)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	if !strings.Contains(result["stdout"].(string), "hello") {
		t.Fatalf("stdout = %q", result["stdout"])
	}
	if result["exit_code"].(int) != 0 {
		t.Fatalf("exit_code = %v", result["exit_code"])
	}
}

func TestExecuteLocalRunCommandCapturesNonZeroExit(t *testing.T) {
	root := t.TempDir()
	params, _ := json.Marshal(runCommandParams{Command: "exit 42"})
	result := executeLocalRunCommand(context.Background(), root, params)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	if result["exit_code"].(int) != 42 {
		t.Fatalf("exit_code = %v", result["exit_code"])
	}
}

func TestExecuteLocalRunCommandRespectTimeout(t *testing.T) {
	root := t.TempDir()
	// 200ms timeout + 500ms WaitDelay headroom = should finish well under 3 seconds.
	params, _ := json.Marshal(runCommandParams{Command: "sleep 60", TimeoutMS: 200})
	start := time.Now()
	result := executeLocalRunCommand(context.Background(), root, params)
	elapsed := time.Since(start)
	if elapsed > 3*time.Second {
		t.Fatalf("command did not timeout in time: %v", elapsed)
	}
	// On a timeout the result carries an error (context kill) or a non-zero exit.
	hasOutcome := result["error"] != nil || result["exit_code"] != nil
	if !hasOutcome {
		t.Fatalf("expected result to contain error or exit_code, got: %v", result)
	}
}

// ---------------------------------------------------------------------------
// Connection loop with mock WebSocket server
// ---------------------------------------------------------------------------

func TestLocalConnectAndServeHandlesRegisteredWithChatSession(t *testing.T) {
	chatID := int64(42)
	srv := newLocalWSServer(t, func(conn *websocket.Conn) {
		// Send welcome.
		conn.WriteJSON(map[string]string{"type": "welcome"})
		// Read subscribe.
		conn.ReadMessage() //nolint:errcheck
		// Send confirm.
		conn.WriteJSON(map[string]string{"type": "confirm_subscription", "identifier": `{"channel":"LocalTunnelChannel"}`})
		// Read register message.
		conn.ReadMessage() //nolint:errcheck
		// Send registered with a chat_session_id.
		conn.WriteJSON(map[string]any{
			"identifier": `{"channel":"LocalTunnelChannel"}`,
			"message": map[string]any{
				"type":              "registered",
				"tunnel_session_id": 1,
				"chat_session_id":   chatID,
			},
		})
		// Close gracefully.
		conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
	})

	var out strings.Builder
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	localConnectAndServe(ctx, &out, wsURL(t, srv), t.TempDir(), "acme/widget", "main") //nolint:errcheck

	if !strings.Contains(out.String(), "chat session #42") {
		t.Fatalf("output = %q", out.String())
	}
}

func TestLocalConnectAndServeHandlesRegisteredWithoutChatSession(t *testing.T) {
	srv := newLocalWSServer(t, func(conn *websocket.Conn) {
		conn.WriteJSON(map[string]string{"type": "welcome"})
		conn.ReadMessage() //nolint:errcheck
		conn.WriteJSON(map[string]string{"type": "confirm_subscription", "identifier": `{"channel":"LocalTunnelChannel"}`})
		conn.ReadMessage() //nolint:errcheck
		conn.WriteJSON(map[string]any{
			"identifier": `{"channel":"LocalTunnelChannel"}`,
			"message": map[string]any{
				"type":              "registered",
				"tunnel_session_id": 1,
				"chat_session_id":   nil,
			},
		})
		conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
	})

	var out strings.Builder
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	localConnectAndServe(ctx, &out, wsURL(t, srv), t.TempDir(), "acme/widget", "main") //nolint:errcheck

	if !strings.Contains(out.String(), "no active Local Mode chat session") {
		t.Fatalf("output = %q", out.String())
	}
}

func TestLocalConnectAndServeExecutesToolCallAndReturnsResult(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("hi there"), 0600); err != nil {
		t.Fatal(err)
	}

	var toolResultReceived map[string]any

	srv := newLocalWSServer(t, func(conn *websocket.Conn) {
		conn.WriteJSON(map[string]string{"type": "welcome"})
		conn.ReadMessage() //nolint:errcheck
		conn.WriteJSON(map[string]string{"type": "confirm_subscription", "identifier": `{"channel":"LocalTunnelChannel"}`})
		conn.ReadMessage() // register
		// Send a registered message first.
		conn.WriteJSON(map[string]any{
			"identifier": `{"channel":"LocalTunnelChannel"}`,
			"message": map[string]any{
				"type":              "registered",
				"tunnel_session_id": 1,
				"chat_session_id":   nil,
			},
		})
		// Send a tool_call.
		params, _ := json.Marshal(readFileParams{Path: "hello.txt"})
		conn.WriteJSON(map[string]any{
			"identifier": `{"channel":"LocalTunnelChannel"}`,
			"message": map[string]any{
				"type":    "tool_call",
				"call_id": "call-1",
				"tool":    "read_file",
				"params":  json.RawMessage(params),
			},
		})
		// Read the tool_result response.
		_, raw, _ := conn.ReadMessage()
		var envelope struct {
			Data string `json:"data"`
		}
		if err := json.Unmarshal(raw, &envelope); err == nil {
			json.Unmarshal([]byte(envelope.Data), &toolResultReceived)
		}
		conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	localConnectAndServe(ctx, &strings.Builder{}, wsURL(t, srv), root, "acme/widget", "main") //nolint:errcheck

	// Give the goroutine a moment to deliver.
	time.Sleep(100 * time.Millisecond)

	if toolResultReceived == nil {
		t.Fatal("did not receive tool result")
	}
	if toolResultReceived["call_id"] != "call-1" {
		t.Fatalf("call_id = %v", toolResultReceived["call_id"])
	}
	result, _ := toolResultReceived["result"].(map[string]any)
	if result["content"] != "hi there" {
		t.Fatalf("result content = %v", result["content"])
	}
}

func TestLocalConnectAndServeReturnsErrorOnRejectedSubscription(t *testing.T) {
	srv := newLocalWSServer(t, func(conn *websocket.Conn) {
		conn.WriteJSON(map[string]string{"type": "welcome"})
		conn.ReadMessage() //nolint:errcheck
		conn.WriteJSON(map[string]string{"type": "disconnect", "reason": "unauthorized"})
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err := localConnectAndServe(ctx, &strings.Builder{}, wsURL(t, srv), t.TempDir(), "acme/widget", "main")
	if err == nil {
		t.Fatal("expected error on rejected subscription")
	}
	if !strings.Contains(err.Error(), "local_mode feature") {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestLocalCommandFailsWithoutCredentials(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	command := NewRootCommand()
	command.SetOut(&strings.Builder{})
	command.SetErr(&strings.Builder{})
	command.SetArgs([]string{"local", "--dir", t.TempDir()})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error when credentials are missing")
	}
}
