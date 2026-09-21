// Package spec is the wire shape of a plugin service request: what Syrus asks
// the runtime manager to run. It is deliberately small. Anything a plugin
// service is not allowed to have -- privileges, devices, host mounts, host
// networking -- is not a field here at all, so it cannot be requested, only
// omitted.
package spec

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
)

// Service describes one plugin-owned container.
type Service struct {
	// Plugin is the Syrus plugin that owns the service, recorded as a label so
	// an operator can tell whose container this is.
	Plugin string `json:"plugin"`

	// Image must be tagged or pinned by digest, and must come from an allowed
	// registry prefix (see policy).
	Image string `json:"image"`

	// InternalPort is the port the service listens on inside the project
	// network. It is never published to the host.
	InternalPort int `json:"internal_port"`

	// Volumes are always Docker named volumes owned by the service. There is
	// no way to express a bind mount.
	Volumes []Volume `json:"volumes,omitempty"`

	Env map[string]string `json:"env,omitempty"`

	// Healthcheck is probed over HTTP by the manager itself, so it works for
	// images that ship without curl or wget.
	Healthcheck *Healthcheck `json:"healthcheck,omitempty"`
}

// Volume is a named volume mounted into the service.
type Volume struct {
	Name      string `json:"name"`
	MountPath string `json:"mount_path"`
}

// Healthcheck is an HTTP GET against the service's internal port.
type Healthcheck struct {
	Path string `json:"path"`
}

// Hash is a stable digest of everything that shapes the container. The manager
// stamps it on the container as a label; a request whose hash differs from the
// running container's replaces it, and one whose hash matches is a no-op. That
// makes Ensure safe to call on every reconcile tick.
func (s Service) Hash() string {
	canonical := s
	canonical.Volumes = append([]Volume(nil), s.Volumes...)
	sort.Slice(canonical.Volumes, func(i, j int) bool {
		return canonical.Volumes[i].Name < canonical.Volumes[j].Name
	})

	// encoding/json writes map keys in sorted order, so Env is canonical too.
	raw, err := json.Marshal(canonical)
	if err != nil {
		// Every field is a plain value; Marshal cannot fail here.
		panic(err)
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}
