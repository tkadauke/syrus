package cmd

import (
	"fmt"
	"strings"
)

var jobStateFilters = []string{
	"all",
	"open",
	"backlog",
	"needs_triage",
	"triaging",
	"blocked_by_epic",
	"queued",
	"running",
	"implemented",
	"coding",
	"failed",
	"no_change_needed",
	"approved",
	"landing",
	"closed",
}

var jobStateFilterHelp = strings.Join(jobStateFilters, ", ")

func validateJobStateFilter(state string) error {
	for _, allowed := range jobStateFilters {
		if state == allowed {
			return nil
		}
	}
	return fmt.Errorf("state must be one of: %s", jobStateFilterHelp)
}
