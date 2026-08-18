---
name: promote
description: Merge the development branch into main once it is stable enough to release, running this repo's own tests first and stopping cleanly on any conflict or failure.
parameters:
  - key: source_branch
    type: string
    required: false
    label: Source branch
    default: development
  - key: target_branch
    type: string
    required: false
    label: Target branch
    default: main
  - key: strategy
    type: select
    options: [merge_commit, fast_forward]
    required: false
    label: Merge strategy
    default: merge_commit
  - key: open_pr
    type: boolean
    required: false
    label: Open a pull request
    default: true
---

Parameters for this run — source_branch=`{{source_branch}}`,
target_branch=`{{target_branch}}`, strategy=`{{strategy}}`,
open_pr=`{{open_pr}}`.

You are promoting `{{source_branch}}` onto `{{target_branch}}` for this
repository. `{{target_branch}}` is stable-branch territory: only this skill
(and the `backport-hotfixes` skill that reconciles the other direction)
touches it. Do not treat this as an ordinary feature change — your job is to
land `{{source_branch}}` cleanly or leave `{{target_branch}}` exactly as it
was.

Your workspace is already checked out on a branch based on the current tip of
`{{target_branch}}` (Syrus set that up when this skill was launched with
`target_branch={{target_branch}}`). Do the promotion on top of that checkout:

1. `git fetch origin {{source_branch}}` to get the latest tip of the source
   branch.
2. Merge it in using the strategy given above:
   - strategy=merge_commit (the default): run
     `git merge --no-ff origin/{{source_branch}}`. Always produces a merge
     commit, even if a fast-forward would have been possible — that keeps
     `{{target_branch}}`'s history showing exactly when each promotion
     happened.
   - strategy=fast_forward: run `git merge --ff-only origin/{{source_branch}}`.
     This refuses instead of merging if `{{target_branch}}` has diverged
     (e.g. a hotfix landed there since the last promotion). Treat that
     refusal the same as a conflict — see step 4 — do not fall back to a
     merge commit yourself; the whole point of asking for fast_forward is a
     linear history, and silently switching strategies defeats that.
3. Before you consider the merge "successful", run this repo's own test and
   lint commands — whatever this repository's `.syrus.yml` `prepare` and
   `grade`/`graders` sections run (`bin/rspec-fast`, `bin/test-react`, the
   migration/lint checks, etc. — read `.syrus.yml` at the repo root rather
   than assuming). A skill run happens outside Syrus's normal deterministic
   grader chain, so nothing downstream will catch a broken `{{target_branch}}`
   if you skip this. Only proceed past this step if every command you run
   succeeds.
4. **On conflict, a refused fast-forward, or a failing test/lint command:**
   stop. Run `git merge --abort` (or `git reset --hard` back to the tip you
   started from if the merge already completed but tests then failed) so
   `{{target_branch}}` is left exactly as it was before you touched it. Do
   not force-push, do not commit a broken merge, and do not try to patch
   your way past a real conflict or a real test failure — those are for a
   human to look at. Explain clearly, in your own words, what you found (the
   conflicting files, or which command failed and how) so the operator can
   act on it. This is a legitimate stopping point, not something to route
   around.
5. **On success:** leave the merge committed on your current branch (do not
   run `git push` or open anything yourself — you do not have GitHub push
   credentials in this workspace). Syrus's own pipeline pushes your branch
   and opens a pull request against `{{target_branch}}` once this step
   finishes, exactly like it does for any other Syrus-managed change; that
   satisfies the default open_pr=true behavior with no further action from
   you.
   - If open_pr=false and strategy=fast_forward produced a genuinely clean
     fast-forward (no merge commit, nothing to review), say so plainly in
     your summary. Syrus's publish step does not currently have a way to
     skip opening a pull request, so one will still be opened even though
     the change is a no-op fast-forward — call that out explicitly rather
     than letting the operator assume a direct push happened silently.

Never invent changes to make this "work" — if `{{source_branch}}` has nothing
new to offer `{{target_branch}}`, or the situation doesn't match any of the
above, explain that instead of manufacturing a diff.
