---
name: backport-hotfixes
description: Reconcile commits present on main but not yet on development, cherry-picking them onto a branch off development in commit order and opening a PR, or reporting exactly which commit conflicted without attempting automatic resolution.
parameters:
  - key: source_branch
    type: string
    required: false
    label: Source branch
    default: main
  - key: target_branch
    type: string
    required: false
    label: Target branch
    default: development
  - key: max_commits
    type: integer
    required: false
    label: Maximum commits to backport
    default: ""
---

Parameters for this run — source_branch=`{{source_branch}}`,
target_branch=`{{target_branch}}`, max_commits=`{{max_commits}}` (empty means
no cap).

You are backporting hotfixes: reconciling `{{target_branch}}` with whatever
commits exist on `{{source_branch}}` that it doesn't have yet. This is
agnostic to how those commits got onto `{{source_branch}}` — a direct hotfix
commit, a cherry-pick from somewhere else, anything. Do not investigate or
second-guess their origin; your job is only to bring `{{target_branch}}` up
to date with them. `{{source_branch}}` is stable-branch territory that only
this skill (read-only) and the `promote` skill (which merges the other
direction) touch — do not modify it.

Your workspace is already checked out on a branch based on the current tip of
`{{target_branch}}` (Syrus set that up when this skill was launched with
`target_branch={{target_branch}}`). Do all of the following on top of that
checkout:

1. `git fetch origin {{source_branch}}` to get the latest tip of the source
   branch.
2. Compute the commits reachable from `{{source_branch}}` that are not
   reachable from `{{target_branch}}`, oldest first:
   `git log --reverse --format=%H origin/{{target_branch}}..origin/{{source_branch}}`.
3. **If that list is empty:** `{{target_branch}}` already has everything
   `{{source_branch}}` has — this is the common case right after a `promote`
   run, since promoting converges the two branches. Do not create any
   commits and do not invent a diff. Simply say so plainly in your summary
   (e.g. "nothing to backport, `{{target_branch}}` and `{{source_branch}}`
   are in sync") and stop; Syrus treats a skill run with no commits as a
   successful no-op, not a failure.
4. **If max_commits is set (non-empty) and the list is longer than that
   number:** keep only the first `max_commits` entries (oldest first, so you
   are always working through the backlog from the front) and note in your
   summary how many commits were left out of this run because of the cap, so
   the operator knows a backlog remains for the next scheduled run.
5. Cherry-pick the remaining commits onto your current branch **in order,
   oldest first**, one at a time: `git cherry-pick <sha>`. Use cherry-pick,
   never `git merge` or `git rebase`, for this direction — merging would
   pull in `{{source_branch}}`'s own merge topology (e.g. unrelated commits
   that happen to share a merge commit with a real hotfix), which is exactly
   what cherry-picking one commit at a time avoids.
6. **On a cherry-pick conflict:** stop immediately. Run `git cherry-pick
   --abort` so your branch is left exactly as it was before that commit was
   attempted (any earlier commits in this run that already picked cleanly
   stay committed — do not undo those). Do not attempt automatic conflict
   resolution, do not skip the conflicting commit and continue with the
   rest, and do not force through a resolution you're not confident in. This
   runs unattended on a schedule; a silently wrong partial backport is worse
   than stopping and asking for help. Report clearly which commit conflicted
   (its SHA and subject line) and which files were in conflict, so a human
   can resolve it manually.
7. **Once every planned commit has cherry-picked cleanly:** before treating
   the backport as done, run this repository's own test and lint commands —
   whatever this repository's `.syrus.yml` `prepare` and `grade`/`graders`
   sections run (`bin/rspec-fast`, `bin/test-react`, the migration/lint
   checks, etc. — read `.syrus.yml` at the repo root rather than assuming).
   A skill run happens outside Syrus's normal deterministic grader chain, so
   nothing downstream will catch a broken `{{target_branch}}` if you skip
   this. Only proceed past this step if every command you run succeeds.
8. **If any of those commands fail:** stop. Reset your branch back to
   `{{target_branch}}`'s starting tip (`git reset --hard
   origin/{{target_branch}}`) so no broken commits are left in place. Report
   which command failed and how, the same way you would report a conflict —
   this is also a legitimate stopping point for a human to look at, not
   something to patch around.
9. **On success:** leave the cherry-picked commits committed on your current
   branch (do not run `git push` or open anything yourself — you do not have
   GitHub push credentials in this workspace). Syrus's own pipeline pushes
   your branch and opens a pull request against `{{target_branch}}` once
   this step finishes. Summarize which commits were backported (SHAs and
   subject lines) so the reviewer can match them back to `{{source_branch}}`.

Never invent commits or changes to make this "work" — if there is genuinely
nothing to backport, or the situation doesn't match any of the above, explain
that instead of manufacturing a diff.
