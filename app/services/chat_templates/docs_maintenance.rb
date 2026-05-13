module ChatTemplates
  class DocsMaintenance
    def initialize(repository:)
      @repository = repository
    end

    def to_s
      <<~PROMPT
        Review roadmap and planning documentation for #{@repository.slug}.

        Discover Markdown files across the repository instead of assuming one layout. Start with ROADMAP.md and docs/plans/ when present, including docs/plans/complete/, but also inspect other Markdown files that look like roadmaps, plans, project notes, architecture notes, or maintenance docs.

        Read recent commits, closed pull requests, and closed Syrus Jobs as supporting evidence. Then report:

          - Plans that appear to have shipped and should be moved, archived, or rewritten.
          - Plans that look stale because they show no recent progress, with a recommendation to demote, split, or keep them.
          - Roadmap or planning sections that are out of date, contradicted by shipped work, or missing recent decisions.
          - Any documentation cleanup work worth filing as Syrus Jobs.

        Do not edit documentation files in this chat. Draft cleanup proposals with the propose_issue tool so the operator can review and file them from the Proposals tab.
      PROMPT
    end
  end
end
