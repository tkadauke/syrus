module Coworkers
  class ReviewPrompt < ::Prompts::AdversarialReview
    def self.protected_instructions
      "You may curate only approved memory/<name>.md files with `update_coworker_review_memory`. When finished, call `submit_coworker_review` with `critique`, a `verdict` of `needs_work` or `approved`, and a concise `key_learning`. Submission durably journals and persists your learning, so call it last."
    end

    private
    def step_orientation = "You are running the coworker_review step for Syrus as the accountable coworker selected by provider routing."
    def submission_instructions = nil
  end
end
