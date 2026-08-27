module Prompts
  # Renders needs_work findings from the adversarial_review / visual_review
  # loops for the repair `implement`/`respond` iteration that follows.
  # Mirrors GradeFailureFeedback's role for the grader retry loop: without
  # this, a reviewer's needs_work verdict advanced the loop to another agent
  # iteration, but that iteration only ever saw the original task prompt
  # again — never the reviewer's critique — so it had no way to know what
  # to fix.
  class ReviewFeedback
    def initialize(intro:, iterations:)
      @intro = intro
      @iterations = Array(iterations)
    end

    def to_s
      return nil if @iterations.empty?

      <<~PROMPT.strip
        #{@intro}

        #{render_iterations}
      PROMPT
    end

    private

    def render_iterations
      @iterations.map { |finding| render_finding(finding) }.join("\n\n")
    end

    def render_finding(finding)
      iteration = finding["iteration"] || finding[:iteration] || "unknown"
      critique = finding["critique"] || finding[:critique] || "(No critique provided.)"

      "Iteration #{iteration}:\n#{critique}"
    end
  end
end
