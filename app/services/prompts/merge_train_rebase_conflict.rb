module Prompts
  # Prompt for resolving a conflict while rebasing an already-built merge-train
  # integration branch onto a moved base branch.
  class MergeTrainRebaseConflict
    def initialize(repo_slug:, integration_branch:, base_branch:, new_base_sha:)
      @repo_slug = repo_slug
      @integration_branch = integration_branch
      @base_branch = base_branch
      @new_base_sha = new_base_sha
    end

    def to_s
      <<~PROMPT.strip
        This is an Epic merge-train stale-base recovery run for `#{@repo_slug}`.
        The local integration branch `#{@integration_branch}` is being rebased onto
        `#{@base_branch}` at `#{@new_base_sha}`. That `git rebase` is already in
        progress in this workspace and has stopped on a conflict.

        Resolve the conflict(s) and complete the in-progress rebase:

        1. Edit each conflicted file so the result keeps the intent of the merge-train
           integration branch and the moved base branch. Remove every conflict marker.
        2. `git add` the resolved files, then `git rebase --continue`. Repeat until the
           rebase finishes.

        Hard rules:
        - Stay on this in-progress rebase. Do not run `git rebase --abort`, start a new
          rebase, or rebase onto any target other than the one already configured.
        - Do not push, open pull requests, edit pull requests, or switch branches.

        When done, the end state must be: no rebase in progress, a clean working tree,
        and `#{@base_branch}` at `#{@new_base_sha}` is an ancestor of HEAD.
      PROMPT
    end
  end
end
