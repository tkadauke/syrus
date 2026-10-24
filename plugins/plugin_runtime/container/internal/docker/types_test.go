package docker

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// HostConfig's safety mostly comes from what it cannot express at all. This
// pins that: if someone adds a dangerous field, this test is where the
// review starts. CapAdd and Devices are the one documented exception (see
// the HostConfig doc comment) -- they are asserted separately below, not in
// the forbidden list.
func TestHostConfigCannotSerializeMostPrivilegedSettings(t *testing.T) {
	raw, err := json.Marshal(HostConfig{
		NetworkMode:   "syrus_default",
		Mounts:        []Mount{{Type: "volume", Source: "v", Target: "/data"}},
		RestartPolicy: RestartPolicy{Name: "unless-stopped"},
		SecurityOpt:   []string{"no-new-privileges:true"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}

	allowed := map[string]bool{"NetworkMode": true, "Mounts": true, "RestartPolicy": true, "SecurityOpt": true}
	for field := range fields {
		if !allowed[field] {
			t.Errorf("HostConfig serialized unexpected field %q -- extending HostConfig is a security change", field)
		}
	}
	for _, forbidden := range []string{"Privileged", "Binds", "PidMode", "IpcMode", "UsernsMode", "PortBindings"} {
		if _, present := fields[forbidden]; present {
			t.Errorf("HostConfig must not be able to express %s", forbidden)
		}
	}
	// CapAdd and Devices are real fields now, but the generic create() path
	// never sets them -- leaving them at their zero value here is what proves
	// that: with omitempty, an unset CapAdd/Devices does not appear at all.
	for _, exception := range []string{"CapAdd", "Devices", "Memory"} {
		if _, present := fields[exception]; present {
			t.Errorf("HostConfig unset %s must not be serialized (omitempty)", exception)
		}
	}
}

// Memory is the one field here that can only take capability away. It still
// has to be pinned: a service must be able to set it, an unset limit must stay
// absent so existing containers keep their unlimited behaviour, and it must not
// drag any privileged field along with it.
func TestHostConfigCanSerializeMemoryWhenExplicitlySet(t *testing.T) {
	raw, err := json.Marshal(HostConfig{
		NetworkMode:   "syrus_default",
		RestartPolicy: RestartPolicy{Name: "unless-stopped"},
		Memory:        2 << 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}

	if got, ok := fields["Memory"]; !ok {
		t.Error("HostConfig must be able to express Memory")
	} else if got != float64(2<<30) {
		t.Errorf("Memory = %v, want %v", got, float64(2<<30))
	}
	for _, forbidden := range []string{"Privileged", "Binds", "CapAdd", "Devices"} {
		if _, present := fields[forbidden]; present {
			t.Errorf("setting Memory must not serialize %s", forbidden)
		}
	}
}

// The narrow exception: CapAdd and Devices can be set and do serialize --
// manager.EnsurePrivileged relies on that -- but only when a caller
// populates them explicitly. Nothing in spec.Service can reach them.
func TestHostConfigCanSerializeCapAddAndDevicesWhenExplicitlySet(t *testing.T) {
	raw, err := json.Marshal(HostConfig{
		CapAdd:  []string{"NET_ADMIN", "NET_RAW"},
		Devices: []DeviceMapping{{PathOnHost: "/dev/net/tun", PathInContainer: "/dev/net/tun", CgroupPermissions: "rwm"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if _, present := fields["CapAdd"]; !present {
		t.Error("expected CapAdd to serialize when set")
	}
	if _, present := fields["Devices"]; !present {
		t.Error("expected Devices to serialize when set")
	}
}

func TestDemuxLogsStripsFrameHeaders(t *testing.T) {
	frame := func(stream byte, text string) []byte {
		header := []byte{stream, 0, 0, 0, 0, 0, 0, byte(len(text))}
		return append(header, text...)
	}
	stream := append(frame(1, "out line\n"), frame(2, "err line\n")...)

	got, err := DemuxLogs(bytes.NewReader(stream))
	if err != nil || got != "out line\nerr line\n" {
		t.Fatalf("got %q, %v", got, err)
	}
	// Cut short by the byte limit mid-frame: keep what arrived.
	if got, _ := DemuxLogs(bytes.NewReader(stream[:12])); got != "out " {
		t.Fatalf("truncated: %q", got)
	}
	// A TTY container's log has no frames.
	if got, _ := DemuxLogs(strings.NewReader("plain text\n")); got != "plain text\n" {
		t.Fatalf("plain: %q", got)
	}
}
