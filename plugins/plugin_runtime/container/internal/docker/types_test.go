package docker

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// HostConfig's safety comes from what it cannot express. This pins that: if
// someone adds a dangerous field, this test is where the review starts.
func TestHostConfigCannotSerializePrivilegedSettings(t *testing.T) {
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
	for _, forbidden := range []string{"Privileged", "CapAdd", "Devices", "Binds", "PidMode", "IpcMode", "UsernsMode", "PortBindings"} {
		if _, present := fields[forbidden]; present {
			t.Errorf("HostConfig must not be able to express %s", forbidden)
		}
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
