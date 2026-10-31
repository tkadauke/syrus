// Package gitexec runs git for the mirror with a scrubbed environment.
//
// Nothing from the container's own environment leaks into git: no user or
// system config, no terminal prompts, no credential helpers. A fetch
// credential travels as an http.extraHeader set through GIT_CONFIG_* variables
// rather than on the command line, so it never appears in a process listing
// and is never written to the repository's config.
package gitexec

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const defaultWaitDelay = 5 * time.Second

var ErrOutputLimit = errors.New("git output exceeds limit")

// Credential is HTTP basic auth for a fetch.
type Credential struct {
	Username string
	Password string
}

// Result is a finished git invocation.
type Result struct {
	Stdout []byte
	Stderr []byte
}

// ExitError is git exiting non-zero. Stderr is kept for diagnosis; it never
// contains the credential, which git receives only through its environment.
type ExitError struct {
	Args   []string
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	return fmt.Sprintf("git %s: exit %d: %s", strings.Join(e.Args, " "), e.Code, strings.TrimSpace(e.Stderr))
}

// Runner runs git with a fixed binary and home directory.
type Runner struct {
	Binary    string
	Home      string
	WaitDelay time.Duration
}

// Run executes git in dir (a bare repository, or "" for none).
func (r Runner) Run(ctx context.Context, dir string, cred *Credential, args ...string) (Result, error) {
	return r.run(ctx, dir, cred, nil, 0, args...)
}

// RunLimited executes git while enforcing a hard stdout ceiling.
func (r Runner) RunLimited(ctx context.Context, dir string, cred *Credential, maxStdout int64, args ...string) (Result, error) {
	return r.run(ctx, dir, cred, nil, maxStdout, args...)
}

// RunLimitedTo streams bounded stdout into destination rather than retaining
// the complete command output in memory.
func (r Runner) RunLimitedTo(ctx context.Context, dir string, cred *Credential, destination io.Writer, maxStdout int64, args ...string) (Result, error) {
	return r.run(ctx, dir, cred, destination, maxStdout, args...)
}

func (r Runner) run(ctx context.Context, dir string, cred *Credential, destination io.Writer, maxStdout int64, args ...string) (Result, error) {
	binary := r.Binary
	if binary == "" {
		binary = "git"
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Dir = dir
	cmd.Env = r.env(cred)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return nil
		}
		return err
	}
	cmd.WaitDelay = r.WaitDelay
	if cmd.WaitDelay == 0 {
		cmd.WaitDelay = defaultWaitDelay
	}
	var stdout, stderr bytes.Buffer
	if destination == nil {
		destination = &stdout
	}
	stdoutWriter := &limitedWriter{destination: destination, remaining: maxStdout}
	if maxStdout <= 0 {
		stdoutWriter.remaining = -1
	}
	cmd.Stdout = stdoutWriter
	cmd.Stderr = &stderr
	err := cmd.Run()
	res := Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
	if stdoutWriter.exceeded {
		return res, ErrOutputLimit
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return res, &ExitError{Args: args, Code: exit.ExitCode(), Stderr: stderr.String()}
		}
		return res, err
	}
	return res, nil
}

type limitedWriter struct {
	destination io.Writer
	remaining   int64
	exceeded    bool
}

func (w *limitedWriter) Write(p []byte) (int, error) {
	if w.remaining < 0 {
		return w.destination.Write(p)
	}
	if int64(len(p)) > w.remaining {
		_, _ = w.destination.Write(p[:w.remaining])
		w.exceeded = true
		return len(p), ErrOutputLimit
	}
	n, err := w.destination.Write(p)
	w.remaining -= int64(n)
	return n, err
}

func (r Runner) env(cred *Credential) []string {
	home := r.Home
	if home == "" {
		home = "/tmp"
	}
	env := []string{
		"HOME=" + home,
		"PATH=/usr/local/bin:/usr/bin:/bin",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_ASKPASS=/bin/false",
		"LC_ALL=C",
	}
	pairs := [][2]string{
		// An empty helper list: never consult or store credentials anywhere.
		{"credential.helper", ""},
	}
	if cred != nil && (cred.Username != "" || cred.Password != "") {
		token := base64.StdEncoding.EncodeToString([]byte(cred.Username + ":" + cred.Password))
		pairs = append(pairs, [2]string{"http.extraHeader", "Authorization: Basic " + token})
	}
	env = append(env, fmt.Sprintf("GIT_CONFIG_COUNT=%d", len(pairs)))
	for i, pair := range pairs {
		env = append(env, fmt.Sprintf("GIT_CONFIG_KEY_%d=%s", i, pair[0]), fmt.Sprintf("GIT_CONFIG_VALUE_%d=%s", i, pair[1]))
	}
	return env
}
