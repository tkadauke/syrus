module Prompts
  # Prompt for the first Run on a Job — just the issue title + body. The
  # agent has nothing else to go on yet (no prior commits, no reviewer
  # feedback). M0+ baseline; richer initial-prompt scaffolding can grow
  # here once we have data from real runs about where the agent gets
  # stuck.
  class Initial
    def initialize(issue:, epic: nil, user: nil, repository_ids: [])
      @issue = issue
      @epic = epic
      @user = user
      @repository_ids = repository_ids
    end

    def to_s
      [ "#{@issue.title}\n\n#{@issue.body}".strip,
        epic_context,
        memory_context,
        GitSafety::TEXT,
        SubmitSummaryInstructions::TEXT ].compact_blank.join("\n\n")
    end

    private

    def epic_context
      Prompts::EpicContext.new(epic: @epic).to_s
    end

    def memory_context
      Prompts::MemoryContext.new(user: @user, repository_ids: @repository_ids).to_s.presence
    end
  end
end
