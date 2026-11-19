//go:build !windows

package cmd

import (
	"fmt"
	"os"
)

func pluginDevDockerUserArgs() []string {
	return []string{"--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())}
}
