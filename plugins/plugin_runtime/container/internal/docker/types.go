package docker

// These mirror the subset of the Docker Engine API the manager uses.

// ContainerSummary is one entry of GET /containers/json.
type ContainerSummary struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Image  string            `json:"Image"`
	State  string            `json:"State"`
	Labels map[string]string `json:"Labels"`
}

// ContainerInspect is the subset of GET /containers/{id}/json the manager reads.
type ContainerInspect struct {
	ID    string `json:"Id"`
	Name  string `json:"Name"`
	State struct {
		Status    string `json:"Status"`
		Running   bool   `json:"Running"`
		ExitCode  int    `json:"ExitCode"`
		Error     string `json:"Error"`
		StartedAt string `json:"StartedAt"`
	} `json:"State"`
	Config struct {
		Image  string            `json:"Image"`
		Labels map[string]string `json:"Labels"`
	} `json:"Config"`
	NetworkSettings struct {
		Networks map[string]struct {
			IPAddress string `json:"IPAddress"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

// CreateContainerRequest is the body of POST /containers/create.
type CreateContainerRequest struct {
	Image            string              `json:"Image"`
	Env              []string            `json:"Env,omitempty"`
	Labels           map[string]string   `json:"Labels"`
	ExposedPorts     map[string]struct{} `json:"ExposedPorts,omitempty"`
	HostConfig       HostConfig          `json:"HostConfig"`
	NetworkingConfig NetworkingConfig    `json:"NetworkingConfig"`
}

// HostConfig models what a plugin service may have, plus one narrow,
// structurally isolated exception.
//
// Binds, PidMode, IpcMode, UsernsMode, PortBindings, Privileged, and host
// networking are not fields of this struct, full stop -- nothing in this
// repository can ever set them. CapAdd and Devices do exist as fields, but
// the generic create() path (driven only by spec.Service, which has no such
// fields) can never populate them: only manager.EnsurePrivileged does, and
// only from a compiled internal/privileged.Definition, never from a decoded
// request. Extending what create() can set from spec.Service is a security
// change and should be reviewed as one; see
// docs/plans/tailscale-privileged-service-lane.md for why CapAdd/Devices
// exist at all and how their one caller is kept separate from every other
// service request.
type HostConfig struct {
	NetworkMode   string          `json:"NetworkMode"`
	Mounts        []Mount         `json:"Mounts,omitempty"`
	RestartPolicy RestartPolicy   `json:"RestartPolicy"`
	SecurityOpt   []string        `json:"SecurityOpt,omitempty"`
	CapAdd        []string        `json:"CapAdd,omitempty"`
	Devices       []DeviceMapping `json:"Devices,omitempty"`
}

// DeviceMapping grants a container access to a host device node. Only
// manager.EnsurePrivileged ever populates this, from a compiled
// internal/privileged.Definition.
type DeviceMapping struct {
	PathOnHost        string `json:"PathOnHost"`
	PathInContainer   string `json:"PathInContainer"`
	CgroupPermissions string `json:"CgroupPermissions"`
}

// Mount is a volume mount. The manager only ever sets Type to "volume".
type Mount struct {
	Type   string `json:"Type"`
	Source string `json:"Source"`
	Target string `json:"Target"`
}

// RestartPolicy lets the daemon restart a crashed service and bring it back
// after a host reboot, without the manager having to supervise it.
type RestartPolicy struct {
	Name string `json:"Name"`
}

// NetworkingConfig attaches the container to the project network with a DNS
// alias, which is how Syrus reaches it.
type NetworkingConfig struct {
	EndpointsConfig map[string]EndpointSettings `json:"EndpointsConfig"`
}

// EndpointSettings configures one network attachment.
type EndpointSettings struct {
	Aliases []string `json:"Aliases,omitempty"`
}

// VolumeSummary is one entry of GET /volumes.
type VolumeSummary struct {
	Name   string            `json:"Name"`
	Labels map[string]string `json:"Labels"`
}
