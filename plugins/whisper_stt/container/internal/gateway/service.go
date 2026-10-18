package gateway

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Upstream                     string
	SessionTimeout, ReapInterval time.Duration
	Client                       *http.Client
}

func ConfigFromEnvironment() Config {
	return Config{Upstream: envOr("WHISPER_UPSTREAM_URL", "http://127.0.0.1:8081"), SessionTimeout: 120 * time.Second, ReapInterval: 5 * time.Second}
}
func Port() string { return envOr("WHISPER_GATEWAY_PORT", "8080") }
func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

type protocolError struct {
	Status  int
	Message string
}

func (e protocolError) Error() string { return e.Message }

type createRequest struct {
	ContentType string `json:"content_type"`
	Language    string `json:"language"`
	Prompt      string `json:"prompt"`
}

type Service struct {
	config      Config
	client      *http.Client
	transcriber transcriber
	factory     decoderFactory
	mu          sync.Mutex
	sessions    map[string]*session
	stop        chan struct{}
	done        chan struct{}
	closeOnce   sync.Once
}

func NewService(config Config) *Service {
	if config.SessionTimeout == 0 {
		config.SessionTimeout = 120 * time.Second
	}
	if config.ReapInterval == 0 {
		config.ReapInterval = 5 * time.Second
	}
	if config.Client == nil {
		config.Client = &http.Client{Timeout: 90 * time.Second}
	}
	s := &Service{config: config, client: config.Client, factory: newMediaDecoder, sessions: map[string]*session{}, stop: make(chan struct{}), done: make(chan struct{})}
	s.transcriber = &upstreamTranscriber{service: s}
	go s.reapLoop()
	return s
}

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Log only method/status-independent routing metadata; bodies, audio, and transcript text never enter logs.
	log.Printf("whisper gateway: %s %s", r.Method, routeName(r.URL.Path))
	defer func() {
		if recover() != nil {
			writeError(w, protocolError{500, "internal server error"})
		}
	}()
	if err := s.route(w, r); err != nil {
		writeError(w, err)
	}
}

func (s *Service) route(w http.ResponseWriter, r *http.Request) error {
	if r.Method == http.MethodGet && r.URL.Path == "/health" {
		return s.health(w, r)
	}
	if r.Method == http.MethodPost && r.URL.Path == "/inference" {
		return s.proxy(w, r)
	}
	if r.Method == http.MethodPost && r.URL.Path == "/stream/sessions" {
		return s.create(w, r)
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 || parts[0] != "stream" || parts[1] != "sessions" {
		return protocolError{404, "not found"}
	}
	id := parts[2]
	if r.Method == http.MethodPut && len(parts) == 5 && parts[3] == "chunks" {
		sequence, err := strconv.Atoi(parts[4])
		if err != nil {
			return protocolError{400, "invalid request"}
		}
		return s.chunk(w, r, id, sequence)
	}
	if r.Method == http.MethodPost && len(parts) == 4 && parts[3] == "finish" {
		return s.finish(w, r, id)
	}
	if r.Method == http.MethodDelete && len(parts) == 3 {
		return s.cancel(w, id)
	}
	return protocolError{404, "not found"}
}

func (s *Service) health(w http.ResponseWriter, r *http.Request) error {
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, s.config.Upstream+"/health", nil)
	response, err := (&http.Client{Timeout: 2 * time.Second}).Do(req)
	healthy := err == nil && response.StatusCode == http.StatusOK
	if response != nil {
		_ = response.Body.Close()
	}
	status := http.StatusServiceUnavailable
	state := "starting"
	if healthy {
		status = 200
		state = "ok"
	}
	writeJSON(w, status, map[string]any{"status": state, "capabilities": map[string]bool{"batch": healthy, "streaming": healthy}})
	return nil
}

func (s *Service) proxy(w http.ResponseWriter, r *http.Request) error {
	if r.ContentLength <= 0 || r.ContentLength > MaxBytes+64*1024 {
		return protocolError{413, "invalid inference request size"}
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxBytes+64*1024+1))
	if err != nil {
		return protocolError{400, "invalid request"}
	}
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, s.config.Upstream+"/inference", bytes.NewReader(body))
	req.Header.Set("Content-Type", r.Header.Get("Content-Type"))
	response, err := s.client.Do(req)
	if err != nil {
		return protocolError{502, "transcription backend failed"}
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return protocolError{502, "transcription backend failed"}
	}
	if response.StatusCode >= 400 {
		return protocolError{response.StatusCode, "transcription backend failed"}
	}
	w.Header().Set("Content-Type", response.Header.Get("Content-Type"))
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(responseBody)
	return nil
}

func (s *Service) create(w http.ResponseWriter, r *http.Request) error {
	var options createRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&options); err != nil && err != io.EOF {
		return protocolError{400, "invalid request"}
	}
	if options.ContentType == "" {
		options.ContentType = "application/octet-stream"
	}
	session, err := newSession(newID(), options, s.factory, s.transcriber)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.sessions[session.id] = session
	s.mu.Unlock()
	writeJSON(w, 201, map[string]string{"id": session.id})
	return nil
}

func (s *Service) chunk(w http.ResponseWriter, r *http.Request, id string, sequence int) error {
	if r.ContentLength <= 0 || r.ContentLength > MaxBytes {
		return protocolError{413, "invalid audio chunk size"}
	}
	audio, err := io.ReadAll(io.LimitReader(r.Body, MaxBytes+1))
	if err != nil || len(audio) == 0 || len(audio) > MaxBytes {
		return protocolError{413, "invalid audio chunk size"}
	}
	session, err := s.find(id)
	if err != nil {
		return err
	}
	text, err := session.append(r.Context(), sequence, audio)
	if err != nil {
		if r.Context().Err() != nil {
			s.drop(id, session)
			session.close()
		}
		return err
	}
	writeJSON(w, 200, map[string]string{"text": text})
	return nil
}

func (s *Service) finish(w http.ResponseWriter, r *http.Request, id string) error {
	session, err := s.take(id)
	if err != nil {
		return err
	}
	defer session.close()
	text, err := session.finish(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]string{"text": text})
	return nil
}
func (s *Service) cancel(w http.ResponseWriter, id string) error {
	session, err := s.take(id)
	if err != nil {
		return err
	}
	session.close()
	writeJSON(w, 200, map[string]bool{"cancelled": true})
	return nil
}
func (s *Service) find(id string) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value := s.sessions[id]
	if value == nil {
		return nil, protocolError{404, "stream session not found"}
	}
	return value, nil
}
func (s *Service) take(id string) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value := s.sessions[id]
	if value == nil {
		return nil, protocolError{404, "stream session not found"}
	}
	delete(s.sessions, id)
	return value, nil
}
func (s *Service) drop(id string, expected *session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sessions[id] == expected {
		delete(s.sessions, id)
	}
}

func (s *Service) reapLoop() {
	ticker := time.NewTicker(s.config.ReapInterval)
	defer ticker.Stop()
	defer close(s.done)
	for {
		select {
		case <-ticker.C:
			s.reap(time.Now())
		case <-s.stop:
			return
		}
	}
}
func (s *Service) reap(now time.Time) {
	var expired []*session
	s.mu.Lock()
	for id, session := range s.sessions {
		if session.stale(now, s.config.SessionTimeout) {
			delete(s.sessions, id)
			expired = append(expired, session)
		}
	}
	s.mu.Unlock()
	for _, session := range expired {
		session.close()
	}
}
func (s *Service) Close() {
	s.closeOnce.Do(func() {
		close(s.stop)
		<-s.done
		s.mu.Lock()
		sessions := s.sessions
		s.sessions = map[string]*session{}
		s.mu.Unlock()
		for _, session := range sessions {
			session.close()
		}
	})
}

type upstreamTranscriber struct{ service *Service }

func (u *upstreamTranscriber) Transcribe(ctx context.Context, session *session, pcm []byte) (string, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("response_format", "json")
	if session.language != "" {
		_ = writer.WriteField("language", session.language)
	}
	if session.prompt != "" {
		_ = writer.WriteField("prompt", session.prompt)
	}
	part, _ := writer.CreateFormFile("file", "dictation.wav")
	_, _ = part.Write(wavBytes(pcm))
	_ = writer.Close()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, u.service.config.Upstream+"/inference", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response, err := u.service.client.Do(req)
	if err != nil {
		return "", protocolError{502, "transcription backend failed"}
	}
	defer response.Body.Close()
	if response.StatusCode >= 400 {
		return "", protocolError{502, "transcription backend failed"}
	}
	var payload struct {
		Text string `json:"text"`
	}
	if json.NewDecoder(response.Body).Decode(&payload) != nil {
		return "", protocolError{502, "transcription backend failed"}
	}
	return strings.TrimSpace(payload.Text), nil
}
func wavBytes(pcm []byte) []byte {
	result := make([]byte, 44+len(pcm))
	copy(result, "RIFF")
	binary.LittleEndian.PutUint32(result[4:], uint32(36+len(pcm)))
	copy(result[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(result[16:], 16)
	binary.LittleEndian.PutUint16(result[20:], 1)
	binary.LittleEndian.PutUint16(result[22:], 1)
	binary.LittleEndian.PutUint32(result[24:], SampleRate)
	binary.LittleEndian.PutUint32(result[28:], SampleRate*2)
	binary.LittleEndian.PutUint16(result[32:], 2)
	binary.LittleEndian.PutUint16(result[34:], 16)
	copy(result[36:], "data")
	binary.LittleEndian.PutUint32(result[40:], uint32(len(pcm)))
	copy(result[44:], pcm)
	return result
}

func routeName(path string) string {
	if path == "/health" {
		return "/health"
	}
	if path == "/inference" {
		return "/inference"
	}
	if strings.HasPrefix(path, "/stream/sessions") {
		return "/stream/sessions"
	}
	return "unknown"
}
func newID() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		panic(err)
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmtID(value)
}
func fmtID(value []byte) string {
	const hex = "0123456789abcdef"
	out := make([]byte, 36)
	positions := []int{0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 14, 15, 16, 17, 19, 20, 21, 22, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35}
	for i, b := range value {
		out[positions[i*2]] = hex[b>>4]
		out[positions[i*2+1]] = hex[b&15]
	}
	out[8] = '-'
	out[13] = '-'
	out[18] = '-'
	out[23] = '-'
	return string(out)
}
func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
func writeError(w http.ResponseWriter, err error) {
	value, ok := err.(protocolError)
	if !ok {
		value = protocolError{500, "internal server error"}
	}
	writeJSON(w, value.Status, map[string]string{"error": value.Message})
}
