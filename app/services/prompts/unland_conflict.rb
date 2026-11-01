module Prompts
  class UnlandConflict
    def initialize(job:, workflow:)
      @job = job
      @workflow = workflow
    end

    def to_s
      shas = Array(@workflow.artifact("unland_commit_shas")).reverse
      <<~PROMPT
        Resolve the in-progress git revert conflicts for this compensating rollback of #{@job.rollback_of.slug}.
        Preserve unrelated changes now present on the default branch. The complete reverse-order sequence is:
        #{shas.map { |sha| "- #{sha}" }.join("\n")}

        Resolve the current conflict, stage it, and run `git revert --continue`. Repeat for every later conflict until
        the sequencer finishes. Leave the resolved changes ready for Syrus to commit, and do not abort the revert,
        rewrite history, or alter the original Job.
      PROMPT
    end
  end
end
