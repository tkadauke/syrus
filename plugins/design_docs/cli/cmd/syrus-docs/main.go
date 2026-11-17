package main

import (
	"fmt"
	"os"

	designdocs "github.com/tkadauke/syrus/plugins/design_docs/cli"
)

func main() {
	command := designdocs.NewDocsCommand()
	command.SetArgs(os.Args[1:])
	if err := command.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
