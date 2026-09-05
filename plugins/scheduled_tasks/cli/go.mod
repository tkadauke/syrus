module github.com/tkadauke/syrus/plugins/scheduled_tasks/cli

go 1.25.0

require (
	github.com/spf13/cobra v1.10.2
	github.com/tkadauke/syrus/cli v0.0.0
)

// The CLI module is never published, so `require` alone sends Go looking for a
// `cli/v0.0.0` tag on the repo. The relative replace resolves it from the
// working tree, and keeps this module buildable with GOWORK=off.
replace github.com/tkadauke/syrus/cli => ../../../cli
