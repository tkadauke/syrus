package manager

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/docker"
)

// fakeDocker is an in-memory daemon. It is deliberately literal about the
// pieces the manager depends on -- label filters, name conflicts, volume
// idempotence -- because those are where a real daemon's behaviour decides
// whether the manager is correct.
type fakeDocker struct {
	mu         sync.Mutex
	images     map[string]bool
	containers map[string]*fakeContainer
	volumes    map[string]map[string]string
	nextID     int

	// pullGate, when set, blocks PullImage until a value arrives: nil to
	// succeed, an error to fail.
	pullGate chan error
	pulls    int
	created  []docker.CreateContainerRequest
}

type fakeContainer struct {
	id       string
	name     string
	req      docker.CreateContainerRequest
	running  bool
	started  time.Time
	restarts int
}

func newFakeDocker() *fakeDocker {
	return &fakeDocker{images: map[string]bool{}, containers: map[string]*fakeContainer{}, volumes: map[string]map[string]string{}}
}

func matches(have, want map[string]string) bool {
	for k, v := range want {
		if have[k] != v {
			return false
		}
	}
	return true
}

func (f *fakeDocker) ImageExists(_ context.Context, ref string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.images[ref], nil
}

func (f *fakeDocker) PullImage(_ context.Context, fromImage, tag string, progress func(int64, int64, string)) error {
	f.mu.Lock()
	f.pulls++
	gate := f.pullGate
	f.mu.Unlock()

	progress(10, 100, "Downloading")
	if gate != nil {
		if err := <-gate; err != nil {
			return err
		}
	}
	ref := fromImage
	if tag != "" {
		ref += ":" + tag
	}
	f.mu.Lock()
	f.images[ref] = true
	f.mu.Unlock()
	return nil
}

func (f *fakeDocker) ListContainers(_ context.Context, labels map[string]string) ([]docker.ContainerSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []docker.ContainerSummary
	for _, c := range f.containers {
		if !matches(c.req.Labels, labels) {
			continue
		}
		state := "exited"
		if c.running {
			state = "running"
		}
		out = append(out, docker.ContainerSummary{ID: c.id, Names: []string{"/" + c.name}, Image: c.req.Image, State: state, Labels: c.req.Labels})
	}
	return out, nil
}

func (f *fakeDocker) InspectContainer(_ context.Context, id string) (docker.ContainerInspect, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := f.containers[id]
	if c == nil {
		return docker.ContainerInspect{}, &docker.APIError{Status: 404, Message: "no such container"}
	}
	var out docker.ContainerInspect
	out.ID = c.id
	out.Name = "/" + c.name
	out.State.Running = c.running
	out.State.StartedAt = c.started.Format(time.RFC3339Nano)
	out.Config.Image = c.req.Image
	out.Config.Labels = c.req.Labels
	out.NetworkSettings.Networks = map[string]struct {
		IPAddress string `json:"IPAddress"`
	}{c.req.HostConfig.NetworkMode: {IPAddress: "10.0.0.5"}}
	return out, nil
}

func (f *fakeDocker) CreateContainer(_ context.Context, name string, req docker.CreateContainerRequest) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.containers {
		if c.name == name {
			return "", &docker.APIError{Status: 409, Message: "name in use"}
		}
	}
	for _, m := range req.HostConfig.Mounts {
		if _, ok := f.volumes[m.Source]; !ok {
			return "", fmt.Errorf("volume %s was not created first", m.Source)
		}
	}
	f.nextID++
	id := fmt.Sprintf("c%d", f.nextID)
	f.containers[id] = &fakeContainer{id: id, name: name, req: req}
	f.created = append(f.created, req)
	return id, nil
}

func (f *fakeDocker) StartContainer(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := f.containers[id]
	if c == nil {
		return &docker.APIError{Status: 404}
	}
	if !c.running {
		c.running = true
		c.started = time.Now()
	}
	return nil
}

func (f *fakeDocker) StopContainer(_ context.Context, id string, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c := f.containers[id]; c != nil {
		c.running = false
		return nil
	}
	return &docker.APIError{Status: 404}
}

func (f *fakeDocker) RestartContainer(_ context.Context, id string, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := f.containers[id]
	if c == nil {
		return &docker.APIError{Status: 404}
	}
	c.running = true
	c.started = time.Now()
	c.restarts++
	return nil
}

func (f *fakeDocker) ContainerLogs(_ context.Context, id string, tail int, _ int64) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.containers[id] == nil {
		return "", &docker.APIError{Status: 404}
	}
	return fmt.Sprintf("last %d lines of %s\n", tail, f.containers[id].name), nil
}

func (f *fakeDocker) RemoveContainer(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.containers[id]; !ok {
		return &docker.APIError{Status: 404}
	}
	delete(f.containers, id)
	return nil
}

func (f *fakeDocker) CreateVolume(_ context.Context, name string, labels map[string]string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.volumes[name]; !ok {
		copied := map[string]string{}
		for k, v := range labels {
			copied[k] = v
		}
		f.volumes[name] = copied
	}
	return nil
}

func (f *fakeDocker) ListVolumes(_ context.Context, labels map[string]string) ([]docker.VolumeSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []docker.VolumeSummary
	for name, l := range f.volumes {
		if matches(l, labels) {
			out = append(out, docker.VolumeSummary{Name: name, Labels: l})
		}
	}
	return out, nil
}

func (f *fakeDocker) RemoveVolume(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.volumes, name)
	return nil
}

func (f *fakeDocker) containerCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.containers)
}

func (f *fakeDocker) volumeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.volumes)
}
