package policy

import (
	"errors"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/runtime-manager/internal/spec"
)

func valid() spec.Service {
	return spec.Service{
		Plugin:       "git_mirror",
		Image:        "ghcr.io/tkadauke/syrus-git-mirror:abc123",
		InternalPort: 8080,
		Volumes:      []spec.Volume{{Name: "data", MountPath: "/data"}},
		Env:          map[string]string{"SYRUS_URL": "http://web:3000"},
		Healthcheck:  &spec.Healthcheck{Path: "/healthz"},
	}
}

func TestValidAcceptsAWellFormedService(t *testing.T) {
	if err := New([]string{"ghcr.io/tkadauke/"}).Validate("git-mirror", valid()); err != nil {
		t.Fatalf("expected valid, got %v", err)
	}
}

func TestRefusalsAreTypedSoTheServerCanMapThemTo422(t *testing.T) {
	err := New([]string{"ghcr.io/tkadauke/"}).Validate("BAD NAME", valid())
	var refused *Error
	if !errors.As(err, &refused) {
		t.Fatalf("expected *policy.Error, got %T %v", err, err)
	}
}

func TestImageAllowlist(t *testing.T) {
	cases := []struct {
		name    string
		allowed []string
		image   string
		ok      bool
	}{
		{"namespace entry admits a repo under it", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke/x:1", true},
		// The trailing slash is what makes a namespace entry safe. Without it a
		// prefix match on "ghcr.io/tkadauke" would admit "ghcr.io/tkadauke-evil".
		{"namespace entry does not admit a lookalike namespace", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke-evil/x:1", false},
		{"exact entry admits only that repository", []string{"docker.io/traefik/whoami"}, "docker.io/traefik/whoami:v1", true},
		{"exact entry does not admit a sibling", []string{"docker.io/traefik/whoami"}, "docker.io/traefik/traefik:v3", false},
		// Normalization: the short Docker Hub form must match the long form in
		// both directions, or the allowlist is trivially bypassed.
		{"short hub form matches a long entry", []string{"docker.io/traefik/whoami"}, "traefik/whoami:v1", true},
		{"long form matches a short entry", []string{"traefik/whoami"}, "docker.io/traefik/whoami:v1", true},
		{"official image normalizes to library/", []string{"docker.io/library/nginx"}, "nginx:1.27", true},
		{"empty allowlist admits nothing", nil, "ghcr.io/tkadauke/x:1", false},
		{"digest pins are allowed", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke/x@sha256:" + strings.Repeat("a", 64), true},
		{"untagged images are refused", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke/x", false},
		{"uppercase is refused", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke/X:1", false},
		{"malformed digest is refused", []string{"ghcr.io/tkadauke/"}, "ghcr.io/tkadauke/x@sha256:short", false},
		{"registry with port is kept as a host", []string{"localhost:5000/"}, "localhost:5000/x:1", true},
		{"whole-registry namespace", []string{"ghcr.io/"}, "ghcr.io/anyone/x:1", true},
		// A Hub org namespace means docker.io/<org>/*, not the official
		// library -- the bug normalizePrefix exists to avoid.
		{"hub org namespace admits its repos", []string{"traefik/"}, "traefik/whoami:v1", true},
		{"hub org namespace does not admit library images", []string{"traefik/"}, "nginx:1.27", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := valid()
			s.Image = tc.image
			err := New(tc.allowed).Validate("svc", s)
			if tc.ok && err != nil {
				t.Fatalf("expected allowed, got %v", err)
			}
			if !tc.ok && err == nil {
				t.Fatalf("expected refusal for %q with %v", tc.image, tc.allowed)
			}
		})
	}
}

func TestVolumeRules(t *testing.T) {
	cases := []struct {
		name    string
		volumes []spec.Volume
		ok      bool
	}{
		{"plain named volume", []spec.Volume{{Name: "data", MountPath: "/data"}}, true},
		{"relative path", []spec.Volume{{Name: "data", MountPath: "data"}}, false},
		{"traversal", []spec.Volume{{Name: "data", MountPath: "/data/../etc"}}, false},
		{"root", []spec.Volume{{Name: "data", MountPath: "/"}}, false},
		{"under /proc", []spec.Volume{{Name: "data", MountPath: "/proc/x"}}, false},
		{"over /etc", []spec.Volume{{Name: "data", MountPath: "/etc"}}, false},
		{"duplicate name", []spec.Volume{{Name: "a", MountPath: "/a"}, {Name: "a", MountPath: "/b"}}, false},
		{"duplicate target", []spec.Volume{{Name: "a", MountPath: "/a"}, {Name: "b", MountPath: "/a"}}, false},
		{"bad name", []spec.Volume{{Name: "../x", MountPath: "/a"}}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := valid()
			s.Volumes = tc.volumes
			err := New([]string{"ghcr.io/tkadauke/"}).Validate("svc", s)
			if tc.ok != (err == nil) {
				t.Fatalf("ok=%v, got err=%v", tc.ok, err)
			}
		})
	}
}

func TestNameEnvPortAndHealthRules(t *testing.T) {
	p := New([]string{"ghcr.io/tkadauke/"})
	mutations := map[string]func(*spec.Service){
		"port zero":            func(s *spec.Service) { s.InternalPort = 0 },
		"port too high":        func(s *spec.Service) { s.InternalPort = 70000 },
		"bad plugin":           func(s *spec.Service) { s.Plugin = "Git Mirror" },
		"lowercase env key":    func(s *spec.Service) { s.Env = map[string]string{"lower": "x"} },
		"nul in env value":     func(s *spec.Service) { s.Env = map[string]string{"K": "a\x00b"} },
		"relative health":      func(s *spec.Service) { s.Healthcheck = &spec.Healthcheck{Path: "healthz"} },
		"health with space":    func(s *spec.Service) { s.Healthcheck = &spec.Healthcheck{Path: "/a b"} },
		"health with fragment": func(s *spec.Service) { s.Healthcheck = &spec.Healthcheck{Path: "/a#b"} },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			s := valid()
			mutate(&s)
			if err := p.Validate("svc", s); err == nil {
				t.Fatal("expected refusal")
			}
		})
	}

	for _, bad := range []string{"", "Svc", "1svc", "svc_underscore", strings.Repeat("a", 41), "svc/../x"} {
		if err := p.Validate(bad, valid()); err == nil {
			t.Errorf("service name %q should be refused", bad)
		}
	}
}
