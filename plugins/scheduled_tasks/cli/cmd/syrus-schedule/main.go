package main

import (
	"fmt"
	"os"

	scheduledtasks "github.com/tkadauke/syrus/plugins/scheduled_tasks/cli"
)

func main() {
	command := scheduledtasks.NewScheduleCommand()
	command.SetArgs(os.Args[1:])
	if err := command.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
