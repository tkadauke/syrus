module ChatTemplates
  class DocsMaintenance
    def initialize(repository:)
      @repository = repository
    end

    def to_s
      <<~PROMPT
        Review ROADMAP.md and every file under docs/plans/, including docs/plans/complete/, for #{@repository.slug}.

        Read recent commits, closed pull requests, and closed Syrus Jobs as supporting evidence. Then report:

          - Plans that appear to have shipped and should be moved, archived, or rewritten.
          - Plans that look stale because they show no recent progress, with a recommendation to demote, split, or keep them.
          - ROADMAP.md sections that are out of date, contradicted by shipped work, or missing recent decisions.
          - Any documentation cleanup work worth filing as Syrus Jobs.

        Do not edit ROADMAP.md or docs/plans/* in this chat. Draft cleanup proposals with the propose_issue tool so the operator can review and file them from the Proposals tab.
      PROMPT
    end
  end
end
