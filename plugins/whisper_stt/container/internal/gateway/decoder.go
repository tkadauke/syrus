package gateway

import (
	"context"
	"io"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

type decoder interface {
	Feed(context.Context, []byte) error
	WaitForGrowth(int, time.Duration) int
	Snapshot(int) []byte
	Discard(int)
	Size() int
	Finish(context.Context) error
	Close()
}

type mediaDecoder struct {
	cmd           *exec.Cmd
	stdin         io.WriteCloser
	stdout        io.ReadCloser
	mu            sync.Mutex
	changed       *sync.Cond
	pcm           []byte
	readerDone    chan struct{}
	processDone   chan error
	processExited bool
	closeOnce     sync.Once
}

func newMediaDecoder(contentType string) (decoder, error) {
	format, ok := map[string]string{"audio/webm": "webm", "audio/ogg": "ogg"}[contentType]
	if !ok {
		return nil, protocolError{Status: 415, Message: "content type does not support streaming"}
	}
	cmd := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-f", format, "-i", "pipe:0",
		"-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	d := &mediaDecoder{cmd: cmd, stdin: stdin, stdout: stdout, readerDone: make(chan struct{}), processDone: make(chan error, 1)}
	d.changed = sync.NewCond(&d.mu)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go d.readOutput()
	go func() { d.processDone <- cmd.Wait() }()
	return d, nil
}

func (d *mediaDecoder) readOutput() {
	defer close(d.readerDone)
	buffer := make([]byte, 8192)
	for {
		n, err := d.stdout.Read(buffer)
		d.mu.Lock()
		d.pcm = append(d.pcm, buffer[:n]...)
		d.changed.Broadcast()
		d.mu.Unlock()
		if err != nil {
			return
		}
	}
}

func (d *mediaDecoder) Feed(ctx context.Context, audio []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if _, err := d.stdin.Write(audio); err != nil {
		return protocolError{Status: 422, Message: "audio decoder rejected the stream"}
	}
	return nil
}

func (d *mediaDecoder) WaitForGrowth(previous int, timeout time.Duration) int {
	deadline := time.Now().Add(timeout)
	d.mu.Lock()
	defer d.mu.Unlock()
	for len(d.pcm) <= previous && time.Now().Before(deadline) {
		timer := time.AfterFunc(time.Until(deadline), d.changed.Broadcast)
		d.changed.Wait()
		timer.Stop()
	}
	return len(d.pcm)
}

func (d *mediaDecoder) Snapshot(length int) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	if length <= 0 || length > len(d.pcm) {
		length = len(d.pcm)
	}
	return append([]byte(nil), d.pcm[:length]...)
}
func (d *mediaDecoder) Discard(length int) { d.mu.Lock(); d.pcm = d.pcm[length:]; d.mu.Unlock() }
func (d *mediaDecoder) Size() int          { d.mu.Lock(); defer d.mu.Unlock(); return len(d.pcm) }

func (d *mediaDecoder) Finish(ctx context.Context) error {
	_ = d.stdin.Close()
	select {
	case err := <-d.processDone:
		d.processExited = true
		<-d.readerDone
		if err != nil {
			return protocolError{Status: 422, Message: "audio decoder could not finalize the stream"}
		}
		return nil
	case <-ctx.Done():
		_ = d.cmd.Process.Kill()
		<-d.processDone
		d.processExited = true
		<-d.readerDone
		return protocolError{Status: 504, Message: "audio decoder timed out"}
	}
}

func (d *mediaDecoder) Close() {
	d.closeOnce.Do(func() {
		_ = d.stdin.Close()
		if d.cmd.Process != nil && !d.processExited {
			_ = d.cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-d.processDone:
			case <-time.After(2 * time.Second):
				_ = d.cmd.Process.Kill()
				<-d.processDone
			}
		}
		<-d.readerDone
		_ = d.stdout.Close()
	})
}
