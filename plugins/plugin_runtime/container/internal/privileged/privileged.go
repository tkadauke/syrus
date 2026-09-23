// Package privileged is the one, narrow exception to what the runtime
// manager's generic service path can express.
//
// The generic spec.Service (see internal/spec) has no field for privileges,
// devices, host mounts, host networking, or published ports -- not disabled,
// absent, so no request can ever ask for them. This package defines a
// separate, structurally isolated request type that can only ever configure
// a small, compiled table of known first-party services -- one entry at
// launch, "tailscale" -- and never anything a plugin manifest declares or a
// caller names.
//
// See docs/plans/tailscale-privileged-service-lane.md for the full design
// and threat-model discussion.
package privileged

import (
	"fmt"
	"strings"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/docker"
)

// Volume is a named volume mounted into a privileged service. Like the
// generic spec.Volume, it is always a Docker named volume -- there is no way
// to express a bind mount here either.
type Volume struct {
	Name      string
	MountPath string
}

// Healthcheck is an HTTP GET against the service's internal port, probed by
// the manager itself.
type Healthcheck struct {
	Path string
}

// Definition is everything one compiled, first-party privileged service is
// allowed to have. Every field but AllowedEnvKeys and FixedEnv is fixed at
// compile time in NewRegistry; a request can only ever supply values for the
// keys named in AllowedEnvKeys, and FixedEnv is resolved once from the
// manager's own process environment -- never from a request either.
type Definition struct {
	Image          string
	InternalPort   int
	CapAdd         []string
	Devices        []docker.DeviceMapping
	Volume         *Volume
	Healthcheck    *Healthcheck
	AllowedEnvKeys []string
	FixedEnv       map[string]string
}

// Registry is the compiled allowlist of privileged services.
type Registry map[string]Definition

// Lookup returns name's Definition, or false if name is not a registered
// privileged service.
func (r Registry) Lookup(name string) (Definition, bool) {
	d, ok := r[name]
	return d, ok
}

// Tailscale's fixed capabilities and device grant: what it takes to run
// tailscaled and bring up a TUN interface. Nothing here is a request field.
var (
	tailscaleCapAdd = []string{"NET_ADMIN", "NET_RAW"}
	tailscaleDevice = docker.DeviceMapping{
		PathOnHost:        "/dev/net/tun",
		PathInContainer:   "/dev/net/tun",
		CgroupPermissions: "rwm",
	}
	// TailscaleAllowedEnvKeys are the only settings a request may configure --
	// exactly the three the admin UI already exposes. There is deliberately no
	// "extra flags" passthrough: a leaked caller token can change these three
	// values and nothing else.
	TailscaleAllowedEnvKeys = []string{"TS_AUTHKEY", "TS_HOSTNAME", "TS_EXIT_NODE"}
)

// NewRegistry returns the compiled table of first-party privileged services.
// image and serveTarget come from the manager's own process environment
// (RUNTIME_MANAGER_TAILSCALE_IMAGE, SYRUS_INTERNAL_WEB_URL) -- operator/
// Compose-controlled, never caller-controlled -- so they are "fixed" in the
// same sense every other Definition field is, even though they are not Go
// literals.
func NewRegistry(tailscaleImage, serveTarget string) Registry {
	return Registry{
		"tailscale": {
			Image:          tailscaleImage,
			InternalPort:   8080,
			CapAdd:         append([]string(nil), tailscaleCapAdd...),
			Devices:        []docker.DeviceMapping{tailscaleDevice},
			Volume:         &Volume{Name: "state", MountPath: "/var/lib/tailscale"},
			Healthcheck:    &Healthcheck{Path: "/healthz"},
			AllowedEnvKeys: append([]string(nil), TailscaleAllowedEnvKeys...),
			FixedEnv:       map[string]string{"TS_SERVE_TARGET": serveTarget},
		},
	}
}

// Error is a privileged request the registry or its validation refuses,
// mapped to 422 by the server -- the same shape and treatment as
// policy.Error, kept as its own type so this package does not need policy's
// unexported constructor.
type Error struct{ msg string }

func (e *Error) Error() string { return e.msg }

func refuse(format string, args ...any) error {
	return &Error{msg: fmt.Sprintf(format, args...)}
}

// NotRegistered refuses a request for a name with no compiled Definition.
func NotRegistered(name string) error {
	return refuse("%q is not a registered privileged service", name)
}

const maxEnvValueBytes = 8192

// ValidateEnv checks a request's env against exactly what def allows: only
// the keys in AllowedEnvKeys, with the same length/NUL-byte rules the
// generic policy package applies to the generic path. Anything else --
// including a key FixedEnv already sets -- is refused.
func ValidateEnv(def Definition, env map[string]string) error {
	allowed := make(map[string]bool, len(def.AllowedEnvKeys))
	for _, key := range def.AllowedEnvKeys {
		allowed[key] = true
	}
	for key, value := range env {
		if !allowed[key] {
			return refuse("env key %q is not allowed for this privileged service", key)
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

// MergeEnv returns a request's env with def's FixedEnv layered on top. Fixed
// values always win: they come from the manager's own environment, never
// from the request, so a caller cannot override them even by accident.
func MergeEnv(def Definition, env map[string]string) map[string]string {
	merged := make(map[string]string, len(env)+len(def.FixedEnv))
	for k, v := range env {
		merged[k] = v
	}
	for k, v := range def.FixedEnv {
		merged[k] = v
	}
	return merged
}
