package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fakeDecoder struct {
	mu               sync.Mutex
	pcm              []byte
	feeds            [][]byte
	finished, closed bool
	feedErr          error
}

func (d *fakeDecoder) Feed(_ context.Context, audio []byte) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.feedErr != nil {
		return d.feedErr
	}
	d.feeds = append(d.feeds, append([]byte(nil), audio...))
	d.pcm = append(d.pcm, make([]byte, pcmBytesPerSecond)...)
	return nil
}
func (d *fakeDecoder) WaitForGrowth(_ int, _ time.Duration) int { return d.Size() }
func (d *fakeDecoder) Snapshot(n int) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	if n <= 0 || n > len(d.pcm) {
		n = len(d.pcm)
	}
	return append([]byte(nil), d.pcm[:n]...)
}
func (d *fakeDecoder) Discard(n int)                { d.mu.Lock(); d.pcm = d.pcm[n:]; d.mu.Unlock() }
func (d *fakeDecoder) Size() int                    { d.mu.Lock(); defer d.mu.Unlock(); return len(d.pcm) }
func (d *fakeDecoder) Finish(context.Context) error { d.finished = true; return nil }
func (d *fakeDecoder) Close()                       { d.mu.Lock(); d.closed = true; d.mu.Unlock() }
func (d *fakeDecoder) isClosed() bool               { d.mu.Lock(); defer d.mu.Unlock(); return d.closed }

type fakeTranscriber struct {
	mu    sync.Mutex
	sizes []int
	texts []string
}

func (t *fakeTranscriber) Transcribe(_ context.Context, _ *session, pcm []byte) (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sizes = append(t.sizes, len(pcm))
	if len(t.texts) == 0 {
		return "text", nil
	}
	value := t.texts[0]
	t.texts = t.texts[1:]
	return value, nil
}

func newTestService(t *testing.T, timeout time.Duration) (*Service, *fakeDecoder, *fakeTranscriber) {
	t.Helper()
	d := &fakeDecoder{}
	tr := &fakeTranscriber{}
	s := NewService(Config{Upstream: "http://127.0.0.1:1", SessionTimeout: timeout, ReapInterval: 5 * time.Millisecond})
	s.factory = func(string) (decoder, error) { return d, nil }
	s.transcriber = tr
	t.Cleanup(s.Close)
	return s, d, tr
}
func request(t *testing.T, s *Service, method, path string, body []byte) (int, map[string]any) {
	t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	r.ContentLength = int64(len(body))
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	var payload map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &payload)
	return w.Code, payload
}

func inferenceRequest(t *testing.T, audio []byte, contentType string) (*http.Request, []byte) {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="file"; filename="dictation"`)
	header.Set("Content-Type", contentType)
	part, err := writer.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(audio); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	payload := body.Bytes()
	r := httptest.NewRequest("POST", "/inference", bytes.NewReader(payload))
	r.ContentLength = int64(len(payload))
	r.Header.Set("Content-Type", writer.FormDataContentType())
	return r, payload
}

func validWebM(size int) []byte {
	value := make([]byte, size)
	copy(value, []byte{0x1a, 0x45, 0xdf, 0xa3})
	return value
}

func TestStreamingProtocolOrdersChunksAndFinalizes(t *testing.T) {
	s, d, tr := newTestService(t, time.Minute)
	tr.texts = []string{"hello", "hello world", "final"}
	status, created := request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	if status != 201 {
		t.Fatalf("create=%d", status)
	}
	id := created["id"].(string)
	_, first := request(t, s, "PUT", "/stream/sessions/"+id+"/chunks/1", []byte("header"))
	_, second := request(t, s, "PUT", "/stream/sessions/"+id+"/chunks/2", []byte("continuation"))
	if first["text"] != "hello" || second["text"] != "hello world" {
		t.Fatalf("texts=%v %v", first, second)
	}
	status, final := request(t, s, "POST", "/stream/sessions/"+id+"/finish", []byte(`{}`))
	if status != 200 || final["text"] != "final" || !d.finished || !d.isClosed() {
		t.Fatalf("finish=%d %v decoder=%+v", status, final, d)
	}
	if len(d.feeds) != 2 || string(d.feeds[1]) != "continuation" {
		t.Fatalf("feeds=%q", d.feeds)
	}
}

func TestRejectsOutOfOrderAndOversizedChunks(t *testing.T) {
	s, d, _ := newTestService(t, time.Minute)
	_, created := request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	id := created["id"].(string)
	status, payload := request(t, s, "PUT", "/stream/sessions/"+id+"/chunks/2", []byte("late"))
	if status != 409 || payload["error"] != "expected chunk 1" || len(d.feeds) != 0 {
		t.Fatalf("response=%d %v feeds=%v", status, payload, d.feeds)
	}
	session, _ := s.find(id)
	session.inputBytes = MaxBytes
	status, payload = request(t, s, "PUT", "/stream/sessions/"+id+"/chunks/1", []byte("overflow"))
	if status != 413 || payload["error"] != "audio stream is too large" {
		t.Fatalf("aggregate limit=%d %v", status, payload)
	}
	session.inputBytes = 0
	d.pcm = make([]byte, InterimWindowBytes+2)
	tr := s.transcriber.(*fakeTranscriber)
	if _, err := session.hypothesis(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if d.Size() > InterimWindowBytes || tr.sizes[0] != CommitBytes {
		t.Fatalf("bounded=%d sizes=%v", d.Size(), tr.sizes)
	}
}

func TestCancelAndTimeoutReapingCloseSessions(t *testing.T) {
	s, d, _ := newTestService(t, 10*time.Millisecond)
	_, created := request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	id := created["id"].(string)
	status, _ := request(t, s, "DELETE", "/stream/sessions/"+id, nil)
	if status != 200 || !d.isClosed() {
		t.Fatalf("cancel=%d closed=%v", status, d.isClosed())
	}
	d2 := &fakeDecoder{}
	s.factory = func(string) (decoder, error) { return d2, nil }
	_, _ = request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	deadline := time.Now().Add(time.Second)
	for !d2.isClosed() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !d2.isClosed() {
		t.Fatal("expired decoder was not closed")
	}
}

func TestDisconnectAndServiceShutdownCloseSessions(t *testing.T) {
	s, d, _ := newTestService(t, time.Minute)
	_, created := request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	id := created["id"].(string)
	d.feedErr = context.Canceled
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest("PUT", "/stream/sessions/"+id+"/chunks/1", bytes.NewReader([]byte("audio"))).WithContext(ctx)
	r.ContentLength = 5
	s.ServeHTTP(httptest.NewRecorder(), r)
	if !d.isClosed() {
		t.Fatal("disconnected request did not close its decoder")
	}
	if _, err := s.find(id); err == nil {
		t.Fatal("disconnected session remains registered")
	}

	d2 := &fakeDecoder{}
	s.factory = func(string) (decoder, error) { return d2, nil }
	_, _ = request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	s.Close()
	if !d2.isClosed() {
		t.Fatal("service shutdown did not close its decoder")
	}
}

func TestHealthAndBatchProxy(t *testing.T) {
	var upstreamRequestID string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(200)
			return
		}
		upstreamRequestID = r.Header.Get("X-Request-ID")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"text":"ok"}`))
	}))
	defer upstream.Close()
	s := NewService(Config{Upstream: upstream.URL})
	defer s.Close()
	status, payload := request(t, s, "GET", "/health", nil)
	if status != 200 || payload["capabilities"].(map[string]any)["streaming"] != true {
		t.Fatalf("health=%d %v", status, payload)
	}
	r, _ := inferenceRequest(t, validWebM(512), "audio/webm")
	r.Header.Set("X-Request-ID", "request-123")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	status = w.Code
	_ = json.Unmarshal(w.Body.Bytes(), &payload)
	if status != 200 || payload["text"] != "ok" {
		t.Fatalf("proxy=%d %v", status, payload)
	}
	if upstreamRequestID != "request-123" || w.Header().Get("X-Request-ID") != "request-123" {
		t.Fatalf("request correlation upstream=%q response=%q", upstreamRequestID, w.Header().Get("X-Request-ID"))
	}
}

func TestBatchProxyMapsUpstreamFailures(t *testing.T) {
	for _, test := range []struct {
		name           string
		upstreamStatus int
		wantStatus     int
	}{
		{"timeout", http.StatusGatewayTimeout, http.StatusGatewayTimeout},
		{"unavailable", http.StatusBadGateway, http.StatusServiceUnavailable},
		{"invalid input", http.StatusUnprocessableEntity, http.StatusUnprocessableEntity},
	} {
		t.Run(test.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.upstreamStatus)
			}))
			defer upstream.Close()
			s := NewService(Config{Upstream: upstream.URL})
			defer s.Close()

			r, _ := inferenceRequest(t, validWebM(512), "audio/webm")
			w := httptest.NewRecorder()
			s.ServeHTTP(w, r)
			status := w.Code
			if status != test.wantStatus {
				t.Fatalf("status=%d want=%d", status, test.wantStatus)
			}
		})
	}
}

func TestBatchProxyRejectsInvalidAudioBeforeUpstream(t *testing.T) {
	upstreamCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		upstreamCalls++
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	s := NewService(Config{Upstream: upstream.URL})
	defer s.Close()

	tests := []struct {
		name, contentType string
		audio             []byte
		want              int
	}{
		{"empty", "audio/webm", nil, http.StatusUnprocessableEntity},
		{"tiny", "audio/webm", validWebM(32), http.StatusUnprocessableEntity},
		{"truncated", "audio/webm", bytes.Repeat([]byte("x"), 512), http.StatusUnprocessableEntity},
		{"unsupported", "text/plain", bytes.Repeat([]byte("x"), 512), http.StatusUnsupportedMediaType},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			r, _ := inferenceRequest(t, test.audio, test.contentType)
			w := httptest.NewRecorder()
			s.ServeHTTP(w, r)
			if w.Code != test.want {
				t.Fatalf("status=%d want=%d body=%s", w.Code, test.want, w.Body.String())
			}
		})
	}
	if upstreamCalls != 0 {
		t.Fatalf("invalid audio reached upstream %d times", upstreamCalls)
	}
}

func TestRealDecoderAcceptsFragmentedWebM(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg unavailable")
	}
	path := filepath.Join(t.TempDir(), "sample.webm")
	cmd := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "libopus", path)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("make webm: %v: %s", err, output)
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	value, err := newMediaDecoder("audio/webm")
	if err != nil {
		t.Fatal(err)
	}
	d := value.(*mediaDecoder)
	defer d.Close()
	cuts := []int{len(encoded) / 7, len(encoded) / 2, len(encoded)}
	start := 0
	for _, end := range cuts {
		previous := d.Size()
		if err := d.Feed(context.Background(), encoded[start:end]); err != nil {
			t.Fatal(err)
		}
		d.WaitForGrowth(previous, time.Second)
		start = end
	}
	if d.Size() == 0 {
		t.Fatal("decoder emitted no PCM before end-of-stream")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := d.Finish(ctx); err != nil {
		t.Fatal(err)
	}
	if d.Size() <= pcmBytesPerSecond {
		t.Fatalf("pcm bytes=%d", d.Size())
	}
}

func TestMediaDecoderCancellationUnblocksPipeWriteAndReapsProcess(t *testing.T) {
	if _, err := exec.LookPath("sleep"); err != nil {
		t.Skip("sleep unavailable")
	}
	media, err := startMediaDecoder(exec.Command("sleep", "30"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = media.Feed(ctx, make([]byte, 4*1024*1024))
	if err != context.DeadlineExceeded {
		t.Fatalf("feed error = %v, want deadline exceeded", err)
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("cancelled feed took %s", elapsed)
	}
	if media.cmd.ProcessState == nil || !media.processExited {
		t.Fatal("decoder process was not reaped")
	}
}

func TestClientCancellationUnblocksSessionFeedAndRemovesSession(t *testing.T) {
	if _, err := exec.LookPath("sleep"); err != nil {
		t.Skip("sleep unavailable")
	}
	media, err := startMediaDecoder(exec.Command("sleep", "30"))
	if err != nil {
		t.Fatal(err)
	}
	s := NewService(Config{Upstream: "http://127.0.0.1:1"})
	s.factory = func(string) (decoder, error) { return media, nil }
	s.transcriber = &fakeTranscriber{}
	t.Cleanup(s.Close)
	_, created := request(t, s, "POST", "/stream/sessions", []byte(`{"content_type":"audio/webm"}`))
	id := created["id"].(string)

	ctx, cancel := context.WithCancel(context.Background())
	r := httptest.NewRequest("PUT", "/stream/sessions/"+id+"/chunks/1", bytes.NewReader(make([]byte, 4*1024*1024))).WithContext(ctx)
	r.ContentLength = 4 * 1024 * 1024
	done := make(chan struct{})
	go func() {
		s.ServeHTTP(httptest.NewRecorder(), r)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond) // the child does not read stdin, so its pipe fills
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("disconnected chunk request remained blocked")
	}
	if media.cmd.ProcessState == nil || !media.processExited {
		t.Fatal("disconnected session did not reap decoder process")
	}
	if _, err := s.find(id); err == nil {
		t.Fatal("disconnected session remains registered")
	}
}

func TestUnsupportedStreamingFormat(t *testing.T) {
	_, err := newMediaDecoder("audio/mp4")
	if err == nil || fmt.Sprint(err) != "content type does not support streaming" {
		t.Fatalf("error=%v", err)
	}
}
