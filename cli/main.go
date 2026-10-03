package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/tkadauke/syrus/cli/cmd"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func main() {
	if err := cmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		var exitStatus cliplugin.ExitStatusError
		if errors.As(err, &exitStatus) {
			os.Exit(exitStatus.ExitStatus())
		}
		os.Exit(1)
	}
}
