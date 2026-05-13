module ChatTemplates
  class Triage
    TARGETS = %w[issues prs].freeze

    def initialize(repository:, target:)
      @repository = repository
      @target = target.to_s
      raise ArgumentError, "target must be issues or prs" unless TARGETS.include?(@target)
    end

    def to_s
      <<~PROMPT
        Triage #{@repository.slug}'s open #{target_label}.

        Use #{tool_name} to review the current open #{target_label}. #{triage_instruction} Suggest labels or closures where that would help, but do not relabel, close, or otherwise act on GitHub.

        When a finding needs code changes, create a follow-up proposal with propose_issue. Otherwise, summarize the recommended operator follow-up directly in the conversation.
      PROMPT
    end

    private

    def target_label
      @target == "prs" ? "PRs" : "issues"
    end

    def tool_name
      @target == "prs" ? "list_open_prs" : "list_open_issues"
    end

    def triage_instruction
      if @target == "prs"
        "Surface stale pull requests with no activity in more than 30 days, and draft pull requests that have been draft for more than 2 weeks."
      else
        "Find duplicate or near-duplicate issues."
      end
    end
  end
end
