module Prompts
  # Rung 3: ask whether a failing grader is actually this branch's fault
  # (workflow-engine-v3).
  #
  # Deliberately narrow. The adjudicator is not asked to fix anything, or to
  # judge the change -- only whether this failure predates the branch. It is
  # the inconclusive branch of `grade.failures: allow_inherited`, not a new
  # authority, so the question it answers is the same one that rule answers
  # deterministically when it can.
  class GraderAdjudication
    def initialize(grader_names:, base_sha:, output:, repository: nil)
      @grader_names = Array(grader_names)
      @base_sha = base_sha
      @output = output.to_s
      @repository = repository
    end

    def to_s
      <<~PROMPT
        A required grader failed on a branch. Decide whether that failure is
        caused by this branch, or whether it was already failing on the base
        revision it started from.

        Repository: #{@repository&.slug || "unknown"}
        Base revision: #{@base_sha.presence || "unknown"}
        Failing graders: #{@grader_names.join(', ')}

        Grader output:
        ```
        #{@output.truncate(6_000)}
        ```

        You are not being asked to fix anything, and you are not judging the
        change itself. Answer only this: is this failure the branch's fault?

        Say "inconclusive" whenever the evidence does not settle it. That is a
        useful answer and costs far less than a confident wrong one -- another
        rung will take the question. In particular, say inconclusive if you
        cannot see what the base revision did, rather than assuming.

        Reply with JSON only:

        {
          "verdict": "uphold" | "dismiss" | "inconclusive",
          "confidence": 0.0-1.0,
          "reason": "one sentence",
          "evidence": ["short, checkable facts"]
        }

        "uphold" means the branch caused it. "dismiss" means it was already
        failing on the base.
      PROMPT
    end
  end
end
