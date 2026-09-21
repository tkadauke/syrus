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

// HostConfig models only what a plugin service may have.
//
// Privileged, CapAdd, Devices, Binds, PidMode, IpcMode, UsernsMode,
// PortBindings and host networking are not fields of this struct. That is the
// enforcement, not a convention: no request, however it was assembled, can
// serialize one of them, so the daemon never sees them. Extending this struct
// is a security change and should be reviewed as one.
type HostConfig struct {
	NetworkMode   string        `json:"NetworkMode"`
	Mounts        []Mount       `json:"Mounts,omitempty"`
	RestartPolicy RestartPolicy `json:"RestartPolicy"`
	SecurityOpt   []string      `json:"SecurityOpt,omitempty"`
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
