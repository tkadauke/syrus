package manager

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/docker"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/spec"
)

const image = "ghcr.io/tkadauke/syrus-git-mirror:abc123"

func service() spec.Service {
	return spec.Service{
		Plugin:       "git_mirror",
		Image:        image,
		InternalPort: 8080,
		Volumes:      []spec.Volume{{Name: "data", MountPath: "/data"}},
		Env:          map[string]string{"SYRUS_URL": "http://web:3000"},
		Healthcheck:  &spec.Healthcheck{Path: "/healthz"},
	}
}

func newManager(d *fakeDocker) *Manager {
	m := New(d, policy.New([]string{"ghcr.io/tkadauke/"}), "syrus", "syrus_default")
	m.Probe = func(context.Context, string) error { return nil }
	return m
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestEnsureCreatesAContainerTheWayThePolicyPromises(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)

	st, err := m.Ensure(context.Background(), "git-mirror", service())
	if err != nil {
		t.Fatal(err)
	}
	if st.State != StateRunning {
		t.Fatalf("state = %s, want running", st.State)
	}
	if st.Endpoint != "http://git-mirror:8080" {
		t.Fatalf("endpoint = %s", st.Endpoint)
	}

	req := d.created[0]
	if req.HostConfig.NetworkMode != "syrus_default" {
		t.Errorf("network = %s", req.HostConfig.NetworkMode)
	}
	if aliases := req.NetworkingConfig.EndpointsConfig["syrus_default"].Aliases; len(aliases) != 1 || aliases[0] != "git-mirror" {
		t.Errorf("aliases = %v; Syrus reaches the service by this name", aliases)
	}
	for _, mount := range req.HostConfig.Mounts {
		if mount.Type != "volume" {
			t.Errorf("mount type %q -- the manager must never create a bind mount", mount.Type)
		}
		if mount.Source != "syrus_plugin_git-mirror_data" {
			t.Errorf("volume = %s", mount.Source)
		}
	}
	if len(req.HostConfig.SecurityOpt) != 1 || req.HostConfig.SecurityOpt[0] != "no-new-privileges:true" {
		t.Errorf("security opts = %v", req.HostConfig.SecurityOpt)
	}
	if req.HostConfig.RestartPolicy.Name != "unless-stopped" {
		t.Errorf("restart policy = %s", req.HostConfig.RestartPolicy.Name)
	}
	if req.Labels[LabelProject] != "syrus" || req.Labels[LabelService] != "git-mirror" || req.Labels[LabelPlugin] != "git_mirror" {
		t.Errorf("labels = %v", req.Labels)
	}
}

// Syrus calls Ensure on every reconcile tick, so a matching request must be a
// no-op rather than churning the container.
func TestEnsureIsIdempotent(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)

	for i := 0; i < 3; i++ {
		if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
			t.Fatal(err)
		}
	}
	if len(d.created) != 1 {
		t.Fatalf("created %d containers, want 1", len(d.created))
	}
}

// A new image tag or env value replaces the container, and the named volume
// carries its data across -- a Syrus upgrade must not re-mirror everything.
func TestEnsureReplacesTheContainerWhenTheSpecChangesButKeepsVolumes(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	d.images["ghcr.io/tkadauke/syrus-git-mirror:def456"] = true
	m := newManager(d)

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	upgraded := service()
	upgraded.Image = "ghcr.io/tkadauke/syrus-git-mirror:def456"
	st, err := m.Ensure(context.Background(), "git-mirror", upgraded)
	if err != nil {
		t.Fatal(err)
	}

	if len(d.created) != 2 || d.containerCount() != 1 {
		t.Fatalf("created=%d live=%d, want the old container replaced", len(d.created), d.containerCount())
	}
	if st.Image != "ghcr.io/tkadauke/syrus-git-mirror:def456" {
		t.Errorf("image = %s", st.Image)
	}
	if d.volumeCount() != 1 {
		t.Errorf("volumes = %d, want the data volume kept", d.volumeCount())
	}
}

func TestEnsureRestartsAStoppedContainerWithTheSameSpec(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)

	st, _ := m.Ensure(context.Background(), "git-mirror", service())
	_ = d.StopContainer(context.Background(), st.ContainerID, 0)

	st, err := m.Ensure(context.Background(), "git-mirror", service())
	if err != nil {
		t.Fatal(err)
	}
	if st.State != StateRunning || len(d.created) != 1 {
		t.Fatalf("state=%s created=%d, want the same container started again", st.State, len(d.created))
	}
}

// A first pull can be gigabytes. Ensure must return straight away and let the
// pull finish in the background rather than hold Syrus's request open.
func TestEnsurePullsInTheBackgroundThenCreates(t *testing.T) {
	d := newFakeDocker()
	d.pullGate = make(chan error)
	m := newManager(d)

	st, err := m.Ensure(context.Background(), "git-mirror", service())
	if err != nil {
		t.Fatal(err)
	}
	if st.State != StatePulling || st.Pull == nil {
		t.Fatalf("state = %s, want pulling with progress", st.State)
	}
	waitFor(t, "progress to be reported", func() bool {
		s, _ := m.Status(context.Background(), "git-mirror")
		return s.Pull != nil && s.Pull.Total == 100
	})

	// A second Ensure while pulling must not start a second pull.
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	d.pullGate <- nil

	waitFor(t, "the container to be created after the pull", func() bool {
		s, _ := m.Status(context.Background(), "git-mirror")
		return s.State == StateRunning
	})
	if d.pulls != 1 {
		t.Errorf("pulls = %d, want 1", d.pulls)
	}
}

func TestAFailedPullIsReportedAndRetriedByTheNextEnsure(t *testing.T) {
	d := newFakeDocker()
	d.pullGate = make(chan error, 1)
	d.pullGate <- errors.New("manifest unknown")
	m := newManager(d)

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the failure to surface", func() bool {
		s, _ := m.Status(context.Background(), "git-mirror")
		return s.State == StateError && s.Error == "manifest unknown"
	})

	d.pullGate <- nil
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the retry to succeed", func() bool {
		s, _ := m.Status(context.Background(), "git-mirror")
		return s.State == StateRunning
	})
}

// Disabling a plugin mid-pull must win: the pull finishing afterwards must not
// resurrect a container the operator just switched off.
func TestRemoveDuringAPullStopsItFromCreatingTheContainer(t *testing.T) {
	d := newFakeDocker()
	d.pullGate = make(chan error)
	m := newManager(d)

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	if err := m.Remove(context.Background(), "git-mirror", false); err != nil {
		t.Fatal(err)
	}
	d.pullGate <- nil

	time.Sleep(50 * time.Millisecond)
	if d.containerCount() != 0 {
		t.Fatal("the finished pull created a container for a removed service")
	}
	if s, _ := m.Status(context.Background(), "git-mirror"); s.State != StateAbsent {
		t.Fatalf("state = %s, want absent", s.State)
	}
}

// Disable keeps the data a mirror took hours to build; uninstall throws it away.
func TestRemoveKeepsVolumesUnlessPurged(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	if err := m.Remove(context.Background(), "git-mirror", false); err != nil {
		t.Fatal(err)
	}
	if d.containerCount() != 0 || d.volumeCount() != 1 {
		t.Fatalf("after disable: containers=%d volumes=%d, want 0 and 1", d.containerCount(), d.volumeCount())
	}

	if err := m.Remove(context.Background(), "git-mirror", true); err != nil {
		t.Fatal(err)
	}
	if d.volumeCount() != 0 {
		t.Fatalf("after purge: volumes=%d, want 0", d.volumeCount())
	}
}

// Purging one service must not touch another's data, or another project's.
func TestPurgeOnlyRemovesThatServicesVolumes(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	d.volumes["syrus_plugin_other_data"] = map[string]string{LabelManaged: "true", LabelProject: "syrus", LabelService: "other"}
	d.volumes["staging_plugin_git-mirror_data"] = map[string]string{LabelManaged: "true", LabelProject: "staging", LabelService: "git-mirror"}
	m := newManager(d)

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	if err := m.Remove(context.Background(), "git-mirror", true); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.volumes["syrus_plugin_other_data"]; !ok {
		t.Error("purge removed another service's volume")
	}
	if _, ok := d.volumes["staging_plugin_git-mirror_data"]; !ok {
		t.Error("purge removed another project's volume")
	}
}

// A service that is slow to come up reads as starting, not as broken, until
// it has had a fair chance.
func TestHealthFailureIsStartingDuringGraceThenUnhealthy(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)
	m.Probe = func(context.Context, string) error { return errors.New("connection refused") }

	st, err := m.Ensure(context.Background(), "git-mirror", service())
	if err != nil {
		t.Fatal(err)
	}
	if st.State != StateStarting {
		t.Fatalf("state = %s, want starting within the grace period", st.State)
	}

	m.Now = func() time.Time { return time.Now().Add(StartupGrace + time.Second) }
	st, _ = m.Status(context.Background(), "git-mirror")
	if st.State != StateUnhealthy || st.Error == "" {
		t.Fatalf("state = %s err=%q, want unhealthy with a reason", st.State, st.Error)
	}
}

func TestPolicyRefusalCreatesNothing(t *testing.T) {
	d := newFakeDocker()
	m := newManager(d)
	bad := service()
	bad.Image = "docker.io/library/alpine:3"

	_, err := m.Ensure(context.Background(), "git-mirror", bad)
	var refused *policy.Error
	if !errors.As(err, &refused) {
		t.Fatalf("expected a policy refusal, got %v", err)
	}
	if d.pulls != 0 || d.containerCount() != 0 {
		t.Fatal("a refused request must not pull or create anything")
	}
}

func TestListIncludesServicesStillPulling(t *testing.T) {
	d := newFakeDocker()
	d.pullGate = make(chan error)
	m := newManager(d)
	defer func() { d.pullGate <- nil }()

	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}
	statuses, err := m.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(statuses) != 1 || statuses[0].State != StatePulling {
		t.Fatalf("statuses = %+v, want the pulling service listed", statuses)
	}
}

// On shutdown the manager takes its containers with it so `docker compose
// down` can remove the project network -- but never another project's, and
// never anyone's data.
func TestStopAllRemovesThisProjectsContainersAndKeepsVolumes(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	d.containers["foreign"] = &fakeContainer{id: "foreign", name: "staging-plugin-git-mirror", running: true,
		req: docker.CreateContainerRequest{Labels: map[string]string{LabelManaged: "true", LabelProject: "staging", LabelService: "git-mirror"}}}
	m := newManager(d)
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}

	if err := m.StopAll(context.Background()); err != nil {
		t.Fatal(err)
	}

	if d.containerCount() != 1 || d.containers["foreign"] == nil {
		t.Fatalf("containers left = %d, want only the other project's", d.containerCount())
	}
	if d.volumeCount() != 1 {
		t.Fatalf("volumes = %d, want the service's volume kept", d.volumeCount())
	}
	// The next reconcile brings it back.
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil || d.containerCount() != 2 {
		t.Fatalf("ensure after stop: containers=%d err=%v", d.containerCount(), err)
	}
}

func TestOperatorActionsStopStartAndRestartTheContainer(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	m := newManager(d)
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}

	if st, err := m.Stop(context.Background(), "git-mirror"); err != nil || st.State != StateStopped {
		t.Fatalf("stop: %+v %v", st, err)
	}
	if d.containerCount() != 1 || d.volumeCount() != 1 {
		t.Fatalf("stop removed something: containers=%d volumes=%d", d.containerCount(), d.volumeCount())
	}
	if st, err := m.Start(context.Background(), "git-mirror"); err != nil || st.State == StateStopped {
		t.Fatalf("start: %+v %v", st, err)
	}
	if _, err := m.Restart(context.Background(), "git-mirror"); err != nil {
		t.Fatal(err)
	}
	for _, c := range d.containers {
		if c.restarts != 1 {
			t.Fatalf("restarts = %d, want 1", c.restarts)
		}
	}
	logs, err := m.Logs(context.Background(), "git-mirror", 50)
	if err != nil || logs != "last 50 lines of syrus-plugin-git-mirror\n" {
		t.Fatalf("logs = %q, %v", logs, err)
	}
}

func TestOperatorActionsOnAMissingServiceAreNotFound(t *testing.T) {
	m := newManager(newFakeDocker())
	if _, err := m.Stop(context.Background(), "git-mirror"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stop: %v", err)
	}
	if _, err := m.Logs(context.Background(), "git-mirror", 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("logs: %v", err)
	}
}

func TestVolumesListStoredDataAndRefuseToDeleteWhatIsInUse(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	d.volumes["staging_plugin_git-mirror_data"] = map[string]string{LabelManaged: "true", LabelProject: "staging", LabelService: "git-mirror", LabelPlugin: "git_mirror"}
	d.volumes["someone-elses"] = map[string]string{}
	m := newManager(d)
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}

	volumes, err := m.Volumes(context.Background())
	if err != nil || len(volumes) != 1 {
		t.Fatalf("volumes = %+v, %v (want only this project's)", volumes, err)
	}
	v := volumes[0]
	if v.Name != "syrus_plugin_git-mirror_data" || v.Plugin != "git_mirror" || !v.InUse || v.SizeBytes == nil {
		t.Fatalf("volume = %+v", v)
	}
	if err := m.RemoveVolume(context.Background(), v.Name); !errors.Is(err, ErrVolumeInUse) {
		t.Fatalf("remove in use: %v", err)
	}
	if err := m.RemoveVolume(context.Background(), "someone-elses"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("remove foreign: %v", err)
	}

	if err := m.Remove(context.Background(), "git-mirror", false); err != nil {
		t.Fatal(err)
	}
	if err := m.RemoveVolume(context.Background(), v.Name); err != nil {
		t.Fatalf("remove after the service is gone: %v", err)
	}
	if d.volumes["someone-elses"] == nil || d.volumes["staging_plugin_git-mirror_data"] == nil {
		t.Fatal("removed a volume the manager does not own for this project")
	}
}

func TestPurgePluginRemovesItsContainersAndVolumesOnly(t *testing.T) {
	d := newFakeDocker()
	d.images[image] = true
	d.volumes["syrus_plugin_other_data"] = map[string]string{LabelManaged: "true", LabelProject: "syrus", LabelService: "other", LabelPlugin: "other_plugin"}
	m := newManager(d)
	if _, err := m.Ensure(context.Background(), "git-mirror", service()); err != nil {
		t.Fatal(err)
	}

	removed, err := m.PurgePlugin(context.Background(), "git_mirror")
	if err != nil || len(removed) != 1 || removed[0] != "syrus_plugin_git-mirror_data" {
		t.Fatalf("removed = %v, %v", removed, err)
	}
	if d.containerCount() != 0 || d.volumes["syrus_plugin_other_data"] == nil {
		t.Fatalf("containers=%d, other plugin's volume kept=%v", d.containerCount(), d.volumes["syrus_plugin_other_data"] != nil)
	}
}
