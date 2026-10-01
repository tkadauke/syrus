module CognitiveReview
  class PostImplementationReviewProvider
    include Syrus::Plugin::PostImplementationReviewProvider

    REVIEW_TRIGGER_KINDS = %w[
      initial
      retry
      pr_comment
      chat_feedback
      manual
      manual_agentic_run
    ].freeze

    def self.review_needed?(job:, trigger_kind:)
      return false unless CognitiveReview.enabled?
      return false unless job&.repository

      REVIEW_TRIGGER_KINDS.include?(trigger_kind.to_s)
    end

    def self.prompt_sections(job:, workflow:, run:)
      [
        <<~PROMPT.strip
          Perform a cognitive review of the final implementation diff for #{job.repository.slug}.

          Flag only changed diff ranges that are likely to create operator attention debt: subtle behavior changes, surprising edge cases, risky coupling, missing verification, migration/data concerns, or places where the implementation is correct but deserves human focus.

          Submit your result with submit_cognitive_review_notes. If no ranges deserve attention, call it with an empty notes array. Do not edit files.

          Agent Memory may already be present in your context if that plugin is enabled. If it is absent, rely on the Job prompt, repository context, and current diff.
        PROMPT
      ]
    end

    def self.required_mcp_tools(job:, workflow:, run:)
      [ Tools::SubmitCognitiveReviewNotesTool.tool_name ]
    end
  end
end
