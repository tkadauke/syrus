//go:build !windows

package cmd

import (
	"fmt"
	"os"
	"testing"
)

func TestPluginDevDockerUserArgsUsesHostIdentity(t *testing.T) {
	got := pluginDevDockerUserArgs()
	want := []string{"--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("Docker user args = %v, want %v", got, want)
	}
}
