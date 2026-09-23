package privileged

import (
	"errors"
	"strings"
	"testing"
)

func TestNewRegistryHasExactlyTailscale(t *testing.T) {
	r := NewRegistry("ghcr.io/tkadauke/syrus-plugin-tailscale:latest", "http://web:80")
	if len(r) != 1 {
		t.Fatalf("registry has %d entries, want exactly 1", len(r))
	}
	def, ok := r.Lookup("tailscale")
	if !ok {
		t.Fatal("expected tailscale to be registered")
	}
	if def.Image != "ghcr.io/tkadauke/syrus-plugin-tailscale:latest" {
		t.Errorf("image = %s", def.Image)
	}
	if def.InternalPort != 8080 {
		t.Errorf("internal port = %d", def.InternalPort)
	}
	if def.Healthcheck == nil || def.Healthcheck.Path != "/healthz" {
		t.Errorf("healthcheck = %+v", def.Healthcheck)
	}
	if def.Volume == nil || def.Volume.MountPath != "/var/lib/tailscale" {
		t.Errorf("volume = %+v, want tailscaled state to persist across container recreation", def.Volume)
	}
}

func TestLookupRefusesAnyOtherName(t *testing.T) {
	r := NewRegistry("img:1", "http://web:80")
	if _, ok := r.Lookup("git-mirror"); ok {
		t.Fatal("git-mirror must not be a privileged service")
	}
	if _, ok := r.Lookup(""); ok {
		t.Fatal("empty name must not resolve")
	}
}

func TestValidateEnvAcceptsOnlyTheAllowedKeys(t *testing.T) {
	def := Definition{AllowedEnvKeys: []string{"TS_AUTHKEY", "TS_HOSTNAME", "TS_EXIT_NODE"}}

	if err := ValidateEnv(def, map[string]string{"TS_AUTHKEY": "tskey-abc", "TS_HOSTNAME": "box"}); err != nil {
		t.Fatalf("expected valid, got %v", err)
	}

	cases := []string{"TS_EXTRA_ARGS", "TS_AUTHKEY ", "authkey", "PATH"}
	for _, key := range cases {
		err := ValidateEnv(def, map[string]string{key: "x"})
		var refused *Error
		if !errors.As(err, &refused) {
			t.Errorf("key %q: expected *privileged.Error, got %v", key, err)
		}
	}
}

func TestValidateEnvRejectsOversizedOrNulValues(t *testing.T) {
	def := Definition{AllowedEnvKeys: []string{"TS_AUTHKEY"}}

	if err := ValidateEnv(def, map[string]string{"TS_AUTHKEY": strings.Repeat("a", maxEnvValueBytes+1)}); err == nil {
		t.Error("expected an oversized value to be refused")
	}
	if err := ValidateEnv(def, map[string]string{"TS_AUTHKEY": "bad\x00value"}); err == nil {
		t.Error("expected a NUL byte to be refused")
	}
}

func TestMergeEnvFixedValuesAlwaysWin(t *testing.T) {
	def := Definition{FixedEnv: map[string]string{"TS_SERVE_TARGET": "http://web:80"}}

	merged := MergeEnv(def, map[string]string{"TS_AUTHKEY": "tskey-abc", "TS_SERVE_TARGET": "http://evil:80"})

	if merged["TS_AUTHKEY"] != "tskey-abc" {
		t.Errorf("TS_AUTHKEY = %q", merged["TS_AUTHKEY"])
	}
	if merged["TS_SERVE_TARGET"] != "http://web:80" {
		t.Errorf("TS_SERVE_TARGET = %q, want the fixed value to win over a caller-supplied one", merged["TS_SERVE_TARGET"])
	}
}

func TestNotRegisteredIsATypedRefusal(t *testing.T) {
	var refused *Error
	if !errors.As(NotRegistered("bogus"), &refused) {
		t.Fatal("expected a *privileged.Error so the server can map it to 422")
	}
}
