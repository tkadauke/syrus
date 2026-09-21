// Package policy decides whether a service request may run.
//
// It lives in the manager, not in Syrus, on purpose. The worker holds the
// manager's token, and the worker runs agents with shell access -- so the
// token must be assumed to leak. The design goal is that holding it buys
// nothing dangerous: the worst a caller can do is run an approved image, with
// named volumes, on the project network, with no extra privileges.
package policy

import (
	"fmt"
	"path"
	"regexp"
	"strings"

	"github.com/tkadauke/syrus/runtime-manager/internal/spec"
)

var (
	serviceNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
	pluginNameRe  = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	volumeNameRe  = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)
	envKeyRe      = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,127}$`)
)

const (
	maxVolumes       = 8
	maxEnvEntries    = 64
	maxEnvValueBytes = 8192
	maxHealthPath    = 256
)

// Paths a volume may not be mounted over inside the container. Mounting a
// named volume there cannot reach the host, but it is never what a plugin
// means and it breaks the container in confusing ways.
var reservedMountRoots = []string{"/proc", "/sys", "/dev", "/etc"}

// Error is a request the policy refuses. The server maps it to 422 so a
// refusal is distinguishable from the Docker daemon failing.
type Error struct{ msg string }

func (e *Error) Error() string { return e.msg }

func refuse(format string, args ...any) error {
	return &Error{msg: fmt.Sprintf(format, args...)}
}

// Policy holds the image allowlist.
type Policy struct {
	allowed []string
}

// New builds a policy from allowlist entries. An entry ending in "/" allows a
// whole namespace; anything else allows exactly one repository. An empty
// allowlist allows nothing: failing closed is the only safe default for
// something that starts containers.
func New(entries []string) Policy {
	var allowed []string
	for _, entry := range entries {
		if normalized := normalizePrefix(entry); normalized != "" {
			allowed = append(allowed, normalized)
		}
	}
	return Policy{allowed: allowed}
}

// Allowed returns the normalized allowlist, for diagnostics.
func (p Policy) Allowed() []string { return append([]string(nil), p.allowed...) }

// Validate checks a request against every rule.
func (p Policy) Validate(name string, s spec.Service) error {
	if !serviceNameRe.MatchString(name) {
		return refuse("service name %q must match %s", name, serviceNameRe)
	}
	if !pluginNameRe.MatchString(s.Plugin) {
		return refuse("plugin %q must match %s", s.Plugin, pluginNameRe)
	}
	if err := p.checkImage(s.Image); err != nil {
		return err
	}
	if s.InternalPort < 1 || s.InternalPort > 65535 {
		return refuse("internal_port %d is out of range", s.InternalPort)
	}
	if err := checkVolumes(s.Volumes); err != nil {
		return err
	}
	if err := checkEnv(s.Env); err != nil {
		return err
	}
	if s.Healthcheck != nil {
		if err := checkHealthPath(s.Healthcheck.Path); err != nil {
			return err
		}
	}
	return nil
}

func (p Policy) checkImage(image string) error {
	ref, err := ParseImage(image)
	if err != nil {
		return refuse("%s", err)
	}
	for _, allowed := range p.allowed {
		if strings.HasSuffix(allowed, "/") {
			// Namespace entry. The trailing slash is what stops
			// "ghcr.io/acme/" from also admitting "ghcr.io/acme-evil/...".
			if strings.HasPrefix(ref.Repository, allowed) {
				return nil
			}
		} else if ref.Repository == allowed {
			return nil
		}
	}
	return refuse("image %s is not in the allowlist", ref.Repository)
}

func checkVolumes(volumes []spec.Volume) error {
	if len(volumes) > maxVolumes {
		return refuse("at most %d volumes are allowed", maxVolumes)
	}
	names := map[string]bool{}
	targets := map[string]bool{}
	for _, v := range volumes {
		if !volumeNameRe.MatchString(v.Name) {
			return refuse("volume name %q must match %s", v.Name, volumeNameRe)
		}
		if names[v.Name] {
			return refuse("volume %q is declared twice", v.Name)
		}
		names[v.Name] = true

		mount := v.MountPath
		if !strings.HasPrefix(mount, "/") || path.Clean(mount) != mount || mount == "/" {
			return refuse("volume %q mount_path %q must be a clean absolute path other than /", v.Name, mount)
		}
		for _, root := range reservedMountRoots {
			if mount == root || strings.HasPrefix(mount, root+"/") {
				return refuse("volume %q may not be mounted under %s", v.Name, root)
			}
		}
		if targets[mount] {
			return refuse("mount_path %q is used twice", mount)
		}
		targets[mount] = true
	}
	return nil
}

func checkEnv(env map[string]string) error {
	if len(env) > maxEnvEntries {
		return refuse("at most %d env entries are allowed", maxEnvEntries)
	}
	for key, value := range env {
		if !envKeyRe.MatchString(key) {
			return refuse("env key %q must match %s", key, envKeyRe)
		}
		if len(value) > maxEnvValueBytes {
			return refuse("env %s exceeds %d bytes", key, maxEnvValueBytes)
		}
		if strings.ContainsRune(value, 0) {
			return refuse("env %s contains a NUL byte", key)
		}
	}
	return nil
}

func checkHealthPath(p string) error {
	if !strings.HasPrefix(p, "/") || len(p) > maxHealthPath || strings.ContainsAny(p, " \t\r\n#") {
		return refuse("healthcheck path %q must start with / and contain no whitespace or fragment", p)
	}
	return nil
}
