// Package manager reconciles plugin services against the Docker daemon.
//
// It keeps no state of its own. Docker is the record: every managed container
// and volume carries labels naming its project and service, so the manager
// can be restarted -- or run a second time -- and simply rediscover what
// exists. The only in-memory state is in-flight image pulls, and losing one is
// harmless: Syrus re-issues Ensure on its next reconcile and the pull starts
// again.
package manager

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/docker"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/spec"
)

// Labels stamped on every managed container and volume.
const (
	LabelManaged    = "dev.syrus.runtime.managed"
	LabelProject    = "dev.syrus.runtime.project"
	LabelService    = "dev.syrus.runtime.service"
	LabelPlugin     = "dev.syrus.runtime.plugin"
	LabelSpec       = "dev.syrus.runtime.spec"
	LabelPort       = "dev.syrus.runtime.port"
	LabelHealthPath = "dev.syrus.runtime.health-path"
)

// Service states reported to Syrus.
const (
	StateAbsent    = "absent"
	StatePulling   = "pulling"
	StateStarting  = "starting"
	StateRunning   = "running"
	StateUnhealthy = "unhealthy"
	StateStopped   = "stopped"
	StateError     = "error"
)

// StartupGrace is how long a container that fails its health probe is reported
// as starting rather than unhealthy. A service that takes a while to come up
// -- a git mirror opening its repositories -- should not flap to unhealthy.
const StartupGrace = 60 * time.Second

// Docker is the subset of the daemon API the manager needs, so tests can run
// against a fake.
type Docker interface {
	ImageExists(ctx context.Context, ref string) (bool, error)
	PullImage(ctx context.Context, fromImage, tag string, progress func(current, total int64, status string)) error
	ListContainers(ctx context.Context, labels map[string]string) ([]docker.ContainerSummary, error)
	InspectContainer(ctx context.Context, id string) (docker.ContainerInspect, error)
	CreateContainer(ctx context.Context, name string, req docker.CreateContainerRequest) (string, error)
	StartContainer(ctx context.Context, id string) error
	StopContainer(ctx context.Context, id string, timeout time.Duration) error
	RestartContainer(ctx context.Context, id string, timeout time.Duration) error
	ContainerLogs(ctx context.Context, id string, tail int, maxBytes int64) (string, error)
	RemoveContainer(ctx context.Context, id string) error
	CreateVolume(ctx context.Context, name string, labels map[string]string) error
	ListVolumes(ctx context.Context, labels map[string]string) ([]docker.VolumeSummary, error)
	RemoveVolume(ctx context.Context, name string) error
}

// Status describes one service.
type Status struct {
	Service     string        `json:"service"`
	Plugin      string        `json:"plugin,omitempty"`
	State       string        `json:"state"`
	Image       string        `json:"image,omitempty"`
	ContainerID string        `json:"container_id,omitempty"`
	Endpoint    string        `json:"endpoint,omitempty"`
	SpecHash    string        `json:"spec_hash,omitempty"`
	ExitCode    *int          `json:"exit_code,omitempty"`
	Pull        *PullProgress `json:"pull,omitempty"`
	Error       string        `json:"error,omitempty"`
}

// PullProgress is aggregate byte progress for an in-flight image pull.
type PullProgress struct {
	Current int64  `json:"current"`
	Total   int64  `json:"total"`
	Status  string `json:"status,omitempty"`
}

type pull struct {
	image   string
	current int64
	total   int64
	status  string
	err     error
	done    bool
}

// Manager reconciles services for one Compose project.
type Manager struct {
	docker  Docker
	policy  policy.Policy
	project string
	network string

	// Probe checks a service's health endpoint. Replaceable in tests.
	Probe func(ctx context.Context, url string) error
	// Now is the clock. Replaceable in tests.
	Now func() time.Time

	mu    sync.Mutex
	pulls map[string]*pull
	locks map[string]*sync.Mutex
}

// New returns a manager placing services on network, labelled as project.
func New(d Docker, p policy.Policy, project, network string) *Manager {
	return &Manager{
		docker:  d,
		policy:  p,
		project: project,
		network: network,
		Probe:   httpProbe,
		Now:     time.Now,
		pulls:   map[string]*pull{},
		locks:   map[string]*sync.Mutex{},
	}
}

// Ensure makes the named service match s: created, running, and on the right
// image. It is idempotent -- a request matching the running container does
// nothing -- so Syrus can call it on every reconcile tick. When the image is
// not present yet, Ensure starts the pull and returns immediately with state
// "pulling"; the container is created when the pull finishes.
func (m *Manager) Ensure(ctx context.Context, name string, s spec.Service) (Status, error) {
	if err := m.policy.Validate(name, s); err != nil {
		return Status{}, err
	}
	ref, err := policy.ParseImage(s.Image)
	if err != nil {
		// Validate already parsed it; this cannot fail.
		return Status{}, err
	}

	lock := m.lockFor(name)
	lock.Lock()
	defer lock.Unlock()

	hash := s.Hash()
	existing, err := m.find(ctx, name)
	if err != nil {
		return Status{}, err
	}
	if existing != nil {
		if existing.Labels[LabelSpec] == hash {
			if existing.State != "running" {
				if err := m.docker.StartContainer(ctx, existing.ID); err != nil {
					return Status{}, err
				}
			}
			m.forgetPull(name, nil)
			return m.Status(ctx, name)
		}
		// The spec changed -- a new image tag, a new env value. Replace the
		// container; its volumes survive because they are named.
		if err := m.removeContainer(ctx, existing.ID); err != nil {
			return Status{}, err
		}
	}

	present, err := m.docker.ImageExists(ctx, ref.String())
	if err != nil {
		return Status{}, err
	}
	if !present {
		m.startPull(name, s, ref)
		return m.Status(ctx, name)
	}
	if err := m.create(ctx, name, s, ref); err != nil {
		return Status{}, err
	}
	m.forgetPull(name, nil)
	return m.Status(ctx, name)
}

// Remove stops and deletes the service's container. Its volumes are kept
// unless purge is set: disabling a plugin should not throw away data that took
// hours to build, but uninstalling it should.
func (m *Manager) Remove(ctx context.Context, name string, purge bool) error {
	lock := m.lockFor(name)
	lock.Lock()
	defer lock.Unlock()

	// Forgetting the pull also stops one that finishes later from creating
	// the container we are deleting.
	m.forgetPull(name, nil)

	existing, err := m.find(ctx, name)
	if err != nil {
		return err
	}
	if existing != nil {
		if err := m.removeContainer(ctx, existing.ID); err != nil {
			return err
		}
	}
	if !purge {
		return nil
	}
	volumes, err := m.docker.ListVolumes(ctx, m.serviceLabels(name))
	if err != nil {
		return err
	}
	for _, v := range volumes {
		if err := m.docker.RemoveVolume(ctx, v.Name); err != nil && !docker.IsNotFound(err) {
			return err
		}
	}
	return nil
}

// Status reports one service's state, probing its health endpoint if it has one.
// ErrNotFound is returned by operator actions on a service that has no
// container -- never created, still pulling, or removed.
var ErrNotFound = errors.New("service has no container")

// MaxLogBytes bounds how much of a container's log one request returns.
const MaxLogBytes = 2 << 20

// Stop stops the service's container without removing it or its volumes.
// Syrus remembers that an operator stopped it and stops reconciling it, so
// the next Ensure does not start it again behind their back.
func (m *Manager) Stop(ctx context.Context, name string) (Status, error) {
	return m.act(ctx, name, func(id string) error { return m.docker.StopContainer(ctx, id, 10*time.Second) })
}

// Start starts a stopped container with its existing spec.
func (m *Manager) Start(ctx context.Context, name string) (Status, error) {
	return m.act(ctx, name, func(id string) error { return m.docker.StartContainer(ctx, id) })
}

// Restart stops and starts the service's container.
func (m *Manager) Restart(ctx context.Context, name string) (Status, error) {
	return m.act(ctx, name, func(id string) error { return m.docker.RestartContainer(ctx, id, 10*time.Second) })
}

// Logs returns the last tail lines of the service's stdout and stderr.
func (m *Manager) Logs(ctx context.Context, name string, tail int) (string, error) {
	existing, err := m.find(ctx, name)
	if err != nil {
		return "", err
	}
	if existing == nil {
		return "", ErrNotFound
	}
	return m.docker.ContainerLogs(ctx, existing.ID, tail, MaxLogBytes)
}

func (m *Manager) act(ctx context.Context, name string, action func(id string) error) (Status, error) {
	lock := m.lockFor(name)
	lock.Lock()
	existing, err := m.find(ctx, name)
	if err == nil && existing == nil {
		err = ErrNotFound
	}
	if err == nil {
		err = action(existing.ID)
	}
	lock.Unlock()
	if err != nil {
		return Status{}, err
	}
	return m.Status(ctx, name)
}

// StopAll removes every container this manager runs for its project, keeping
// their volumes, and forgets pulls in progress. The manager calls it when it
// shuts down: the containers are not Compose's, so without this they would
// keep the project network busy and `docker compose down` could not remove
// it. Nothing is lost -- state lives in the volumes, and the next reconcile
// after the manager starts again recreates every service still wanted.
func (m *Manager) StopAll(ctx context.Context) error {
	m.mu.Lock()
	for name := range m.pulls {
		delete(m.pulls, name)
	}
	m.mu.Unlock()

	containers, err := m.docker.ListContainers(ctx, m.projectLabels())
	if err != nil {
		return err
	}
	var errs []error
	for _, c := range containers {
		if err := m.removeContainer(ctx, c.ID); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (m *Manager) Status(ctx context.Context, name string) (Status, error) {
	st := Status{Service: name}

	m.mu.Lock()
	p := m.pulls[name]
	var snapshot pull
	if p != nil {
		snapshot = *p
	}
	m.mu.Unlock()

	if p != nil && !snapshot.done {
		st.State = StatePulling
		st.Image = snapshot.image
		st.Pull = &PullProgress{Current: snapshot.current, Total: snapshot.total, Status: snapshot.status}
		return st, nil
	}

	existing, err := m.find(ctx, name)
	if err != nil {
		return st, err
	}
	if existing == nil {
		if p != nil && snapshot.err != nil {
			st.State = StateError
			st.Image = snapshot.image
			st.Error = snapshot.err.Error()
			return st, nil
		}
		st.State = StateAbsent
		return st, nil
	}

	detail, err := m.docker.InspectContainer(ctx, existing.ID)
	if err != nil {
		return st, err
	}
	labels := detail.Config.Labels
	st.ContainerID = detail.ID
	st.Image = detail.Config.Image
	st.Plugin = labels[LabelPlugin]
	st.SpecHash = labels[LabelSpec]
	port := labels[LabelPort]
	st.Endpoint = fmt.Sprintf("http://%s:%s", name, port)

	if !detail.State.Running {
		exit := detail.State.ExitCode
		st.ExitCode = &exit
		st.State = StateStopped
		if detail.State.Error != "" {
			st.State = StateError
			st.Error = detail.State.Error
		}
		return st, nil
	}

	path := labels[LabelHealthPath]
	if path == "" {
		st.State = StateRunning
		return st, nil
	}
	ip := detail.NetworkSettings.Networks[m.network].IPAddress
	if ip == "" {
		st.State = StateStarting
		return st, nil
	}
	if err := m.Probe(ctx, fmt.Sprintf("http://%s:%s%s", ip, port, path)); err != nil {
		st.State = StateUnhealthy
		if started, perr := time.Parse(time.RFC3339Nano, detail.State.StartedAt); perr == nil && m.Now().Sub(started) < StartupGrace {
			st.State = StateStarting
		}
		st.Error = err.Error()
		return st, nil
	}
	st.State = StateRunning
	return st, nil
}

// List reports every managed service in the project, including ones still
// pulling their image and so not yet a container.
func (m *Manager) List(ctx context.Context) ([]Status, error) {
	containers, err := m.docker.ListContainers(ctx, m.projectLabels())
	if err != nil {
		return nil, err
	}
	names := map[string]bool{}
	for _, c := range containers {
		if name := c.Labels[LabelService]; name != "" {
			names[name] = true
		}
	}
	m.mu.Lock()
	for name := range m.pulls {
		names[name] = true
	}
	m.mu.Unlock()

	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	sort.Strings(sorted)

	out := make([]Status, 0, len(sorted))
	for _, name := range sorted {
		st, err := m.Status(ctx, name)
		if err != nil {
			return nil, err
		}
		out = append(out, st)
	}
	return out, nil
}

func (m *Manager) startPull(name string, s spec.Service, ref policy.ImageRef) {
	m.mu.Lock()
	if existing := m.pulls[name]; existing != nil && !existing.done && existing.image == ref.String() {
		m.mu.Unlock()
		return
	}
	p := &pull{image: ref.String()}
	m.pulls[name] = p
	m.mu.Unlock()

	go func() {
		// Detached from the request on purpose: the request that asked for
		// this service returns immediately, and the pull must outlive it.
		ctx := context.Background()
		fromImage, tag := ref.PullParams()
		err := m.docker.PullImage(ctx, fromImage, tag, func(current, total int64, status string) {
			m.mu.Lock()
			p.current, p.total, p.status = current, total, status
			m.mu.Unlock()
		})

		lock := m.lockFor(name)
		lock.Lock()
		defer lock.Unlock()

		m.mu.Lock()
		current := m.pulls[name] == p
		if err != nil {
			p.err, p.done = err, true
		}
		m.mu.Unlock()
		// Remove, or a newer Ensure with a different image, superseded us.
		if err != nil || !current {
			return
		}

		existing, ferr := m.find(ctx, name)
		switch {
		case ferr != nil:
			m.failPull(p, ferr)
		case existing != nil:
			m.forgetPull(name, p)
		default:
			if cerr := m.create(ctx, name, s, ref); cerr != nil {
				m.failPull(p, cerr)
				return
			}
			m.forgetPull(name, p)
		}
	}()
}

func (m *Manager) failPull(p *pull, err error) {
	m.mu.Lock()
	p.err, p.done = err, true
	m.mu.Unlock()
}

// forgetPull drops the pull record for name -- only if it is still `only`,
// when only is non-nil, so a finishing pull cannot delete a newer one's record.
func (m *Manager) forgetPull(name string, only *pull) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if only == nil || m.pulls[name] == only {
		delete(m.pulls, name)
	}
}

func (m *Manager) create(ctx context.Context, name string, s spec.Service, ref policy.ImageRef) error {
	labels := m.serviceLabels(name)
	labels[LabelPlugin] = s.Plugin

	mounts := make([]docker.Mount, 0, len(s.Volumes))
	for _, v := range s.Volumes {
		volume := m.volumeName(name, v.Name)
		if err := m.docker.CreateVolume(ctx, volume, labels); err != nil {
			return err
		}
		// Always "volume", never "bind": there is no path from a request to
		// the host filesystem.
		mounts = append(mounts, docker.Mount{Type: "volume", Source: volume, Target: v.MountPath})
	}

	containerLabels := make(map[string]string, len(labels)+3)
	for k, v := range labels {
		containerLabels[k] = v
	}
	containerLabels[LabelSpec] = s.Hash()
	containerLabels[LabelPort] = strconv.Itoa(s.InternalPort)
	if s.Healthcheck != nil {
		containerLabels[LabelHealthPath] = s.Healthcheck.Path
	}

	env := make([]string, 0, len(s.Env))
	for key, value := range s.Env {
		env = append(env, key+"="+value)
	}
	sort.Strings(env)

	req := docker.CreateContainerRequest{
		Image:        ref.String(),
		Env:          env,
		Labels:       containerLabels,
		ExposedPorts: map[string]struct{}{fmt.Sprintf("%d/tcp", s.InternalPort): {}},
		HostConfig: docker.HostConfig{
			NetworkMode:   m.network,
			Mounts:        mounts,
			RestartPolicy: docker.RestartPolicy{Name: "unless-stopped"},
			// Nothing in a plugin service should gain privileges through
			// setuid binaries, whatever image it came from.
			SecurityOpt: []string{"no-new-privileges:true"},
		},
		NetworkingConfig: docker.NetworkingConfig{
			EndpointsConfig: map[string]docker.EndpointSettings{
				m.network: {Aliases: []string{name}},
			},
		},
	}

	id, err := m.docker.CreateContainer(ctx, m.containerName(name), req)
	if docker.IsConflict(err) {
		// Someone else created it between our check and our create -- a
		// second manager, or a manual `docker run`. Adopt what is there.
		existing, ferr := m.find(ctx, name)
		if ferr != nil {
			return ferr
		}
		if existing == nil {
			return err
		}
		id = existing.ID
	} else if err != nil {
		return err
	}
	return m.docker.StartContainer(ctx, id)
}

func (m *Manager) removeContainer(ctx context.Context, id string) error {
	if err := m.docker.StopContainer(ctx, id, 10*time.Second); err != nil && !docker.IsNotFound(err) {
		return err
	}
	if err := m.docker.RemoveContainer(ctx, id); err != nil && !docker.IsNotFound(err) {
		return err
	}
	return nil
}

func (m *Manager) find(ctx context.Context, name string) (*docker.ContainerSummary, error) {
	containers, err := m.docker.ListContainers(ctx, m.serviceLabels(name))
	if err != nil {
		return nil, err
	}
	if len(containers) == 0 {
		return nil, nil
	}
	return &containers[0], nil
}

func (m *Manager) lockFor(name string) *sync.Mutex {
	m.mu.Lock()
	defer m.mu.Unlock()
	lock := m.locks[name]
	if lock == nil {
		lock = &sync.Mutex{}
		m.locks[name] = lock
	}
	return lock
}

func (m *Manager) projectLabels() map[string]string {
	return map[string]string{LabelManaged: "true", LabelProject: m.project}
}

func (m *Manager) serviceLabels(name string) map[string]string {
	labels := m.projectLabels()
	labels[LabelService] = name
	return labels
}

func (m *Manager) containerName(name string) string {
	return fmt.Sprintf("%s-plugin-%s", m.project, name)
}

func (m *Manager) volumeName(name, volume string) string {
	return fmt.Sprintf("%s_plugin_%s_%s", m.project, name, volume)
}

var errUnhealthyStatus = errors.New("health endpoint returned an error status")

func httpProbe(ctx context.Context, url string) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%w: %d", errUnhealthyStatus, resp.StatusCode)
	}
	return nil
}
