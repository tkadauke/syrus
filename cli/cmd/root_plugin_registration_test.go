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
	for _, forbidden := range []string{"global_search/cli", "spending_insights/cli", "globalsearch.NewSearchCommand", "spendinginsights.NewSpendingCommand"} {
		if strings.Contains(source, forbidden) {
			t.Errorf("root.go still contains compiled-in plugin registration %q", forbidden)
		}
	}
}
