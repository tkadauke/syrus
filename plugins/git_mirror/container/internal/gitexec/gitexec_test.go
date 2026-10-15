package gitexec

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCredentialTravelsInTheEnvironmentNotTheArguments(t *testing.T) {
	env := Runner{}.env(&Credential{Username: "x-access-token", Password: "s3cret"})
	want := "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:s3cret"))

	found := false
	for _, entry := range env {
		if strings.HasSuffix(entry, want) && strings.HasPrefix(entry, "GIT_CONFIG_VALUE_") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected the credential as a GIT_CONFIG value, got %v", env)
	}
}

func TestCancellationDoesNotWaitForAChildHoldingOutputPipes(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "git")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nsleep 10 &\nexec sleep 10\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err := (Runner{Binary: script, WaitDelay: 100 * time.Millisecond}).Run(ctx, dir, nil, "fetch")
	if err == nil {
		t.Fatal("expected cancellation error")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Run waited %v for a child that inherited its output pipes", elapsed)
	}
}

func TestNoCredentialMeansNoAuthorizationHeader(t *testing.T) {
	for _, entry := range (Runner{}).env(nil) {
		if strings.Contains(entry, "Authorization") {
			t.Fatalf("unexpected header in %q", entry)
		}
	}
}

func TestExitErrorCarriesStderr(t *testing.T) {
	_, err := Runner{}.Run(context.Background(), t.TempDir(), nil, "rev-parse", "--verify", "no-such-ref")
	exit, ok := err.(*ExitError)
	if !ok {
		t.Fatalf("expected *ExitError, got %T %v", err, err)
	}
	if exit.Code == 0 || exit.Stderr == "" {
		t.Fatalf("expected a non-zero exit with stderr, got %+v", exit)
	}
}
