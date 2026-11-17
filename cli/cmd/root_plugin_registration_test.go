package cmd

import (
	"os"
	"strings"
	"testing"
)

func TestRootDoesNotCompileFullyServerBackedPluginRegistrations(t *testing.T) {
	payload, err := os.ReadFile("root.go")
	if err != nil {
		t.Fatal(err)
	}
	source := string(payload)
	for _, forbidden := range []string{"plugins/", "globalsearch.NewSearchCommand", "spendinginsights.NewSpendingCommand", "NewCredentialStoreCommand", "NewK8sCommand", "NewScheduleCommand", "NewDocsCommand"} {
		if strings.Contains(source, forbidden) {
			t.Errorf("root.go still contains compiled-in plugin registration %q", forbidden)
		}
	}
}
