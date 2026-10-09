package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

// The Claude Code skill teaches a local agent session how to drive Syrus
// through this CLI (docs/cli-desktop-plan.md, phase 2). It lives here — not
// in the desktop app — so clone-based users get it too; the desktop app's
// one-click install shells out to `syrus skill install`.
const skillFileName = "SKILL.md"

const skillContents = `---
name: syrus
description: Drive a Syrus instance (issue→PR automation) through the syrus CLI — review the inbox, inspect jobs and test plans, check out branches locally, approve jobs for landing, and chat with the instance.
---

# Syrus CLI

Syrus turns GitHub issues into pull requests with an agent doing the
implementation. This machine has the ` + "`syrus`" + ` CLI installed and signed in
(credentials in ` + "`.syrus/credentials`" + ` under your home directory; run
` + "`syrus whoami`" + ` to confirm the instance and user).

## Reviewing work

- ` + "`syrus inbox`" + ` — implemented and failed jobs awaiting a human.
- ` + "`syrus jobs [--closed] [--repo <owner/name>]`" + ` — list jobs.
- ` + "`syrus job show JOB-<id>`" + ` — one job's state, PR, workflow history.
- ` + "`syrus job diff JOB-<id>`" + ` — the job's full diff (review without a checkout).
- ` + "`syrus job log JOB-<id>`" + ` / ` + "`syrus job watch JOB-<id>`" + ` — run logs, once or live.
- ` + "`syrus test-plan [JOB-<id>]`" + ` — the reviewer-facing test plan.
- ` + "`syrus epic show EPIC-<number>`" + ` / ` + "`syrus epic list`" + ` — epics and their children.
- ` + "`syrus repo list`" + ` / ` + "`syrus schedule list`" + ` — repositories and recurring tasks.

## Acting

- ` + "`syrus checkout JOB-<id>`" + ` — fetch and check out the job's PR branch in
  the matching local repository.
- ` + "`syrus status [--json]`" + ` — which job's branch this working directory has.
- ` + "`syrus approve JOB-<id>`" + ` — approve for landing (Syrus merges it).
- ` + "`syrus job create`" + ` — file new work as a direct job (no GitHub issue needed).
- ` + "`syrus chat CHAT_ID \"message\"`" + ` — one streaming chat turn with the
  instance's agent (it can inspect code, queue and propose work).

Output is human-formatted text (only ` + "`status`" + ` speaks ` + "`--json`" + `); prefer the
narrow read commands above over parsing wide listings.

## Guardrails

- ` + "`syrus approve`" + ` merges real pull requests. Only approve when the user
  explicitly asked for that job to be approved.
- Before ` + "`syrus checkout`" + `, make sure the working tree is clean — never
  discard uncommitted local changes to switch branches.
- Prefer read commands (inbox, job show, test-plan, status) when the user's
  intent is to review; mutating commands only on explicit instruction.
- If a command answers ` + "`401 Unauthorized`" + `, the saved token is stale — tell
  the user to open the Syrus desktop app (it refreshes credentials
  automatically) or run ` + "`syrus login`" + `.
`

func NewSkillCommand() *cobra.Command {
	skillCmd := &cobra.Command{
		Use:           "skill",
		Short:         "Manage the Claude Code skill for Syrus",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	skillCmd.AddCommand(newSkillInstallCommand())
	return skillCmd
}

func newSkillInstallCommand() *cobra.Command {
	var skillsDir string

	installCmd := &cobra.Command{
		Use:           "install",
		Short:         "Install the Syrus skill for Claude Code",
		Long:          "Writes the Syrus skill to Claude Code's skills directory so local agent sessions know how to drive Syrus through this CLI.",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := skillsDir
			if dir == "" {
				home, err := os.UserHomeDir()
				if err != nil {
					return err
				}
				dir = filepath.Join(home, ".claude", "skills")
			}

			target := filepath.Join(dir, "syrus", skillFileName)
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(target, []byte(skillContents), 0o644); err != nil {
				return err
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Installed the Syrus skill to %s\n", target)
			fmt.Fprintln(cmd.OutOrStdout(), "New Claude Code sessions will pick it up automatically.")
			return nil
		},
	}

	installCmd.Flags().StringVar(&skillsDir, "dir", "", "skills directory to install into (default ~/.claude/skills)")
	return installCmd
}
