package gateway

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"
)

const (
	SampleRate         = 16000
	pcmBytesPerSecond  = SampleRate * 2
	InterimWindowBytes = 15 * pcmBytesPerSecond
	CommitBytes        = 10 * pcmBytesPerSecond
	minTranscribeBytes = pcmBytesPerSecond / 2
	MaxBytes           = 10 * 1024 * 1024
)

type transcriber interface {
	Transcribe(context.Context, *session, []byte) (string, error)
}
type decoderFactory func(string) (decoder, error)

type session struct {
	id, contentType, language, prompt string
	nextSequence, inputBytes          int
	committedText, lastText           string
	updatedAt                         time.Time
	decoder                           decoder
	transcriber                       transcriber
	mu                                sync.Mutex
}

func newSession(id string, options createRequest, factory decoderFactory, transcriber transcriber) (*session, error) {
	d, err := factory(options.ContentType)
	if err != nil {
		return nil, err
	}
	return &session{id: id, contentType: options.ContentType, language: options.Language, prompt: options.Prompt,
		nextSequence: 1, updatedAt: time.Now(), decoder: d, transcriber: transcriber}, nil
}

func (s *session) append(ctx context.Context, sequence int, audio []byte) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sequence != s.nextSequence {
		return "", protocolError{Status: 409, Message: fmt.Sprintf("expected chunk %d", s.nextSequence)}
	}
	if s.inputBytes+len(audio) > MaxBytes {
		return "", protocolError{Status: 413, Message: "audio stream is too large"}
	}
	previous := s.decoder.Size()
	if err := s.decoder.Feed(ctx, audio); err != nil {
		return "", err
	}
	s.inputBytes += len(audio)
	s.nextSequence++
	s.updatedAt = time.Now()
	if s.decoder.WaitForGrowth(previous, time.Second) == previous {
		return s.lastText, nil
	}
	return s.hypothesis(ctx, false)
}

func (s *session) finish(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inputBytes == 0 {
		return "", protocolError{Status: 422, Message: "audio stream is empty"}
	}
	finishCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := s.decoder.Finish(finishCtx); err != nil {
		return "", err
	}
	return s.hypothesis(ctx, true)
}

func (s *session) hypothesis(ctx context.Context, final bool) (string, error) {
	for s.decoder.Size() > InterimWindowBytes {
		text, err := s.transcriber.Transcribe(ctx, s, s.decoder.Snapshot(CommitBytes))
		if err != nil {
			return "", err
		}
		s.committedText = joinText(s.committedText, text)
		s.decoder.Discard(CommitBytes)
	}
	remaining := s.decoder.Snapshot(0)
	if len(remaining) < minTranscribeBytes && !final {
		return s.lastText, nil
	}
	tail := ""
	if len(remaining) > 0 {
		var err error
		tail, err = s.transcriber.Transcribe(ctx, s, remaining)
		if err != nil {
			return "", err
		}
	}
	s.lastText = joinText(s.committedText, tail)
	return s.lastText, nil
}

func (s *session) close() { s.mu.Lock(); defer s.mu.Unlock(); s.decoder.Close() }
func joinText(parts ...string) string {
	var clean []string
	for _, part := range parts {
		if p := strings.TrimSpace(part); p != "" {
			clean = append(clean, p)
		}
	}
	return strings.Join(clean, " ")
}
