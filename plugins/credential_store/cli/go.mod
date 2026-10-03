module github.com/tkadauke/syrus/plugins/credential_store/cli

go 1.25.0

require (
	github.com/spf13/cobra v1.10.2
	github.com/tkadauke/syrus/cli v0.0.0
)

require (
	github.com/aymanbagabas/go-osc52/v2 v2.0.1 // indirect
	github.com/charmbracelet/colorprofile v0.4.3 // indirect
	github.com/charmbracelet/lipgloss v1.1.1-0.20250404203927-76690c660834 // indirect
	github.com/charmbracelet/x/ansi v0.11.8 // indirect
	github.com/charmbracelet/x/cellbuf v0.0.15 // indirect
	github.com/charmbracelet/x/term v0.2.2 // indirect
	github.com/clipperhouse/displaywidth v0.11.0 // indirect
	github.com/clipperhouse/uax29/v2 v2.7.0 // indirect
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/lucasb-eyer/go-colorful v1.4.1 // indirect
	github.com/mattn/go-isatty v0.0.24 // indirect
	github.com/mattn/go-runewidth v0.0.30 // indirect
	github.com/muesli/termenv v0.16.0 // indirect
	github.com/rivo/uniseg v0.4.7 // indirect
	github.com/spf13/pflag v1.0.10 // indirect
	github.com/xo/terminfo v1.0.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

// The CLI module is never published, so `require` alone sends Go looking for a
// `cli/v0.0.0` tag on the repo. The relative replace resolves it from the
// working tree, and keeps this module buildable with GOWORK=off.
replace github.com/tkadauke/syrus/cli => ../../../cli
