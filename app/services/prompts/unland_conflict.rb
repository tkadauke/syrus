module Prompts
  class UnlandConflict
    def initialize(job:)
      @job = job
    end

    def to_s
      <<~PROMPT
        Resolve the in-progress git revert conflicts for this compensating rollback of #{@job.rollback_of.slug}.
        Preserve unrelated changes now present on the default branch. Finish every pending revert in the recorded order,
        verify the worktree is clean, and commit the resolution. Do not rewrite history or alter the original Job.
      PROMPT
    end
  end
end
