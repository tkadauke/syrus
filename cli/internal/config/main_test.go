package config

import (
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	for _, name := range []string{"SYRUS_CLI_URL", "SYRUS_CLI_INVOCATION_CONTEXT", "SYRUS_CLI_INTERNAL"} {
		os.Unsetenv(name)
	}

	os.Exit(m.Run())
}
