module Adjudicators
  # Rung 3: one bounded agent turn asking whether a failing grader is the
  # branch's fault (workflow-engine-v3).
  #
  # This is the *inconclusive branch* of `grade.failures: allow_inherited`, not
  # a new authority. When MainBranchFailureClassifier can prove the failure is
  # inherited it already says so for free at rung 0; this is what happens when
  # it cannot tell and the alternative is waking someone up.
  #
  # Three rules from the plan, all enforced here:
  #
  #   1. It never takes the action. Like every adjudicator, its verdict is only
  #      acted on where the call site pre-authorized it.
  #   2. It is never the agent that produced the diff -- Judgment runs a fresh
  #      session with no workspace, so there is no continuity with the six
  #      turns that just failed the grader. A model that has been failing a
  #      grader is the worst-calibrated judge of whether the grader is right.
  #   3. `inconclusive` is first class and cheap to say. The prompt asks for it
  #      explicitly, and anything the model returns that is not a known verdict
  #      becomes inconclusive rather than a guess.
  #
  # It costs a turn every time it runs, so it only runs where the work
  # definition's ladder includes rung 3 (see AttentionLadder).
  module AgenticGraderReview
    # Below this, the model is telling us it could not tell.
    MIN_CONFIDENCE = 0.7

    def self.adjudicate(problem:, workflow: nil, step: nil, **)
      return skip("not_a_grader_failure") unless problem&.code == "grader_failure"
      return skip("no_workflow") unless workflow
      return skip("ladder_excludes_rung_3") unless AttentionLadder.adjudicates?(workflow.trigger_kind)

      steps = Array(step).select { |candidate| candidate.respond_to?(:details) }
      return skip("no_failed_graders") if steps.empty?

      verdict_from(judge(workflow, steps))
    end

    def self.judge(workflow, steps)
      Judgment.call(
        scope: "grader-adjudication",
        prompt: Prompts::GraderAdjudication.new(
          grader_names: steps.map { |candidate| candidate.details["name"] }.compact,
          base_sha: workflow.artifact("base_sha"),
          output: steps.map { |candidate| candidate.details["output"] }.compact.join("\n\n"),
          repository: workflow.job&.repository
        ).to_s,
        user: workflow.user,
        provider: workflow.agent_provider,
        schema: %w[verdict reason]
      )
    end

    def self.verdict_from(judgment)
      return skip("judgment_failed: #{judgment.error}") if judgment.failed?

      verdict = judgment.value["verdict"].to_s
      confidence = judgment.value["confidence"].to_f
      reason = judgment.value["reason"].to_s
      evidence = { cited: Array(judgment.value["evidence"]).map(&:to_s), cost_usd: judgment.cost_usd }.compact

      return skip("unknown_verdict_#{verdict}") unless Adjudication::VERDICTS.map(&:to_s).include?(verdict)
      return skip("low_confidence_#{confidence}") if verdict != "inconclusive" && confidence < MIN_CONFIDENCE

      Adjudication.new(verdict, reason: reason, adjudicator: name, confidence: confidence, evidence: evidence)
    end

    def self.skip(reason) = Adjudication.inconclusive(adjudicator: name, reason: reason)

    def self.name = "agentic_grader_review"
  end
end
