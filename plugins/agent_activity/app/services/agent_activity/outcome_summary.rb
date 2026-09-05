module AgentActivity
  # The one-line headline for a session card: whatever that specific Run's
  # session actually submitted, never inferred from transcript text.
  #
  # submit_summary lands directly on the Run (agent_summary/agent_pr_title),
  # so that's a straight read. submit_adversarial_review and
  # submit_visual_review land on the shared Workflow#artifacts iterations
  # array, tagged with the submitting Step's `iteration` -- match that back to
  # this Run's step to find the entry this specific session produced (a
  # workflow can run several adversarial_review/visual_review iterations, one
  # Run each).
  REVIEW_ARTIFACT_KEYS = {
    "adversarial_review" => "adversarial_review_iterations",
    "visual_review" => "visual_review_iterations"
  }.freeze

  class OutcomeSummary
    def self.for(run)
      new(run).call
    end

    def initialize(run)
      @run = run
    end

    def call
      artifact_key = REVIEW_ARTIFACT_KEYS[step&.kind]
      return review_entry_summary(artifact_key) if artifact_key

      { text: @run.agent_summary.presence, verdict: nil }
    end

    private

    def step
      @run.step
    end

    def review_entry_summary(artifact_key)
      entry = review_entry(artifact_key)
      return { text: entry["critique"].presence, verdict: entry["verdict"].presence } if entry

      { text: @run.agent_summary.presence, verdict: nil }
    end

    def review_entry(artifact_key)
      workflow = @run.workflow
      return nil unless workflow

      Array(workflow.artifact(artifact_key)).find do |candidate|
        candidate.is_a?(Hash) && candidate["iteration"].to_i == step.iteration.to_i
      end
    end
  end
end
