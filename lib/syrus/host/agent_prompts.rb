module Syrus
  module Host
    # Renders the shared prompt fragments plugins compose into their own agent
    # prompts. Each method returns the fragment as a String and reads core on
    # every call; the prompt classes behind them are not exposed.
    module AgentPrompts
      class << self
        # The remembered context for a user across the given repositories, or
        # an empty string when no memory store is registered.
        def memory_context(user:, repository_ids:)
          Prompts::MemoryContext.new(user:, repository_ids:).to_s
        end

        # The system prompt a chat agent starts a turn with.
        def chat_system(repository:, chat_session:)
          Prompts::ChatSystem.new(repository:, chat_session:).to_s
        end

        # The git-safety rules appended to agent prompts that may commit.
        def git_safety_text = Prompts::GitSafety::TEXT

        # The instructions telling an agent how to submit its final summary.
        def submit_summary_instructions_text = Prompts::SubmitSummaryInstructions::TEXT
      end
    end
  end
end
