module Prompts
  class CoworkerReview < AdversarialReview
    private
    def step_orientation = "You are running the coworker_review step for Syrus as the accountable coworker selected by provider routing."
    def submission_instructions
      "When finished, call the `submit_coworker_review` MCP tool with `critique` and a `verdict` of `needs_work` or `approved`."
    end
  end
end
