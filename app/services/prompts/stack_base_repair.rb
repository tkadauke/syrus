module Prompts
  # Prompts for the stacked-base finalization barrier's two agentic rungs.
  #
  #   conflict   - the completed work conflicts with the live parent head; the
  #                workspace is already inside the conflicted rebase.
  #   validation - the work was rebased cleanly (or resolved) but the required
  #                graders fail on the rebased tree.
  class StackBaseRepair
    def initialize(kind:, branch_name:, parent_ref:, live_sha:, prepared_sha:, evidence: {})
      @kind = kind.to_s
      @branch_name = branch_name
      @parent_ref = parent_ref
      @live_sha = live_sha
      @prepared_sha = prepared_sha
      @evidence = evidence.to_h
    end

    def to_s
      [ context, @kind == "validation" ? validation_instructions : conflict_instructions, GitSafety::TEXT ].join("\n\n---\n\n")
    end

    private

    def context
      <<~SECTION.strip
        This is a stacked-base repair run for branch `#{@branch_name}`. The implementation is
        complete, but its parent branch `#{@parent_ref}` was rebased while it ran, so it may not be
        published against the old ancestry.

        - Live parent head: `#{@live_sha}`
        - Parent head the work was prepared from: `#{@prepared_sha.presence || 'unknown'}`
      SECTION
    end

    def conflict_instructions
      paths = Array(@evidence["conflicting_paths"])
      <<~SECTION.strip
        Replaying the completed commits (`git rebase --onto #{@live_sha} #{@prepared_sha.presence || '<prepared>'}`)
        conflicts, and that rebase is in progress in this workspace.

        Conflicting paths: #{paths.any? ? paths.map { |path| "`#{path}`" }.join(', ') : '(see `git status`)'}

        Rebase evidence:
        ```
        #{@evidence['rebase_output'].to_s.strip.presence || '(none recorded)'}
        ```

        - Resolve each conflict, preserving both the parent's changes and the completed implementation.
        - `git add` the resolved files and `git rebase --continue` until the rebase finishes with a clean tree.
        - Make the smallest edits needed; do not broaden the feature or change unrelated code.
        - Do not push. Syrus re-runs the required graders and re-checks the live parent afterwards.
      SECTION
    end

    def validation_instructions
      failures = Array(@evidence["validation_failures"])
      rendered = failures.map do |failure|
        <<~FAILURE.strip
          ### `#{failure['command']}`#{' (timed out)' if failure['timed_out']}
          ```
          #{failure['output_tail'].to_s.strip}
          ```
        FAILURE
      end
      <<~SECTION.strip
        The work is rebased onto the live parent, but these required graders fail on the rebased tree:

        #{rendered.join("\n\n").presence || '(no failure output was recorded; run the repository graders yourself)'}

        - Reproduce each failing command, then fix the cause (usually an interaction between the work and the parent's new changes).
        - Commit the fix on this branch; keep the rebased history intact (no new rebase, no reset).
        - Do not push. Syrus re-runs the required graders and re-checks the live parent afterwards.
      SECTION
    end
  end
end
