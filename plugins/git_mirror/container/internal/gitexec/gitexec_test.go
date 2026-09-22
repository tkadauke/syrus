package gitexec

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
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
