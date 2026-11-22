module Prompts
  # Prompt for resolving the conflict pr_open hit while replaying a stacked
  # Job's finished work onto its restacked parent. The workspace is already in
  # the conflicted rebase state when the agent starts, and the work has never
  # been published, so this workspace holds its only copy.
  class StackBaseRebase
    def initialize(repo_slug:, branch_name:, parent_ref:, live_ref:, conflicted_files: [])
      @repo_slug = repo_slug
      @branch_name = branch_name
      @parent_ref = parent_ref
      @live_ref = live_ref
      @conflicted_files = Array(conflicted_files).filter_map { |file| file.is_a?(Hash) ? file["path"] : file.to_s }.reject(&:blank?)
    end

    def to_s
      [
        context,
        instructions,
        GitSafety::TEXT
      ].join("\n\n---\n\n")
    end

    private

    def context
      files = @conflicted_files.any? ? "\n\nFiles that conflicted when Syrus tried: #{@conflicted_files.map { |file| "`#{file}`" }.join(', ')}." : ""
      <<~SECTION.strip
        This is a conflict-resolution run for branch `#{@branch_name}` in `#{@repo_slug}`.

        The work on this branch is finished, but it is stacked on `#{@parent_ref}`,
        and that parent was rebased while the work ran. Before opening the pull
        request, Syrus started replaying this branch's own commits onto the parent's
        current head (`#{@live_ref}`). That rebase has conflicts and is already in
        progress in this workspace. The branch has never been pushed, so this
        workspace holds the only copy of the work.#{files}
      SECTION
    end

    def instructions
      <<~SECTION.strip
        Resolve the in-progress rebase:

        - Inspect `git status` to see the conflicted files.
        - Keep the parent's current changes and this branch's changes; where both edit the same code, combine them so each still does what it did.
        - Make the smallest edits needed to resolve the conflicts.
        - Run `git add <resolved files>` and `git rebase --continue`.
        - Continue until the rebase is complete and the working tree is clean.
        - Do not drop this branch's commits, broaden the change, or edit unrelated code.
        - Do not push. Syrus validates the result and opens the pull request.

        If the conflict cannot be resolved, leave a clear explanation in your final message and leave the rebase in progress.
      SECTION
    end
  end
end
