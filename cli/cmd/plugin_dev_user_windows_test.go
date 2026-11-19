//go:build windows

package cmd

import "testing"

func TestPluginDevDockerUserArgsOmitsUnixIdentity(t *testing.T) {
	if got := pluginDevDockerUserArgs(); len(got) != 0 {
		t.Fatalf("Docker user args = %v, want none", got)
	}
}
