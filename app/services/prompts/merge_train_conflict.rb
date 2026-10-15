module Prompts
  # Prompt for resolving a textual conflict while integrating an Epic's
  # member branch into the merge-train integration branch. Syrus has a
  # `git rebase` onto the integration branch already IN PROGRESS and
  # stopped at a conflict; the agent resolves it and completes that same
  # rebase. Deliberately self-contained — it does NOT load the rebase
  # skill, because that skill rebases onto the repo's default branch
  # (master), which is the wrong target here.
  class MergeTrainConflict
    include GithubContentTrust

    def initialize(repo_slug:, member_branch:, integration_branch:, pr_number:)
      @repo_slug = repo_slug
      @member_branch = member_branch
      @integration_branch = integration_branch
      @pr_number = pr_number
    end

    def to_s
      <<~PROMPT.strip
        #{github_content_trust_boundary}

        This is an **Epic merge-train integration** run. A `git rebase` of the member
        pull request `#{sanitize_github_content(@repo_slug)}##{@pr_number}` (branch `#{sanitize_github_content(@member_branch)}`) onto the
        local branch `#{sanitize_github_content(@integration_branch)}` is **already in progress** in this
        workspace and has stopped on a merge conflict.

        Resolve the conflict(s) and **complete the in-progress rebase**:

        1. Edit each conflicted file so the result keeps the intent of BOTH the
           member's change and everything already on `#{sanitize_github_content(@integration_branch)}`. Remove
           every conflict marker.
        2. `git add` the resolved files, then `git rebase --continue`. Repeat until the
           rebase finishes (there may be more than one conflicting commit).

        Hard rules — do not break these:
        - Stay on THIS in-progress rebase. Do NOT run `git rebase --abort`, do NOT start
          a new rebase, and do NOT rebase onto `origin/master`, `master`, or any branch
          other than the one already being rebased onto.
        - Do NOT push, do NOT open or edit pull requests, do NOT switch branches.

        When you are done the end state MUST be: no rebase in progress, a clean working
        tree (`git status` shows nothing to commit), and `#{sanitize_github_content(@integration_branch)}` is an
        ancestor of `HEAD`.
      PROMPT
    end
  end
end
