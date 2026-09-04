module Adjudicators
  # The LandingValidationCache's reuse decision, stated as a rung-0
  # adjudicator.
  #
  # A landing whose exact head already graded green does not need the graders
  # re-run, and a failure raised while re-running them is not evidence about
  # the code. Only a recorded validation for *this* head counts -- a stale one
  # is inconclusive, never a dismissal.
  module ValidatedLanding
    def self.adjudicate(problem:, workflow: nil, **)
      return Adjudication.inconclusive(adjudicator: name) unless problem&.code == "grader_failure"

      job = workflow&.job
      # The head this workflow actually graded, recorded as an artifact by the
      # steps that push or grade; absent means we cannot tell, not that it is
      # unvalidated.
      head_sha = workflow&.artifact("head_sha")
      return Adjudication.inconclusive(adjudicator: name) if job.nil? || head_sha.blank?
      return Adjudication.inconclusive(adjudicator: name, reason: "no_validation_for_head") unless LandingValidationCache.valid_head_for?(job: job, head_sha: head_sha)

      Adjudication.dismiss(
        adjudicator: name,
        reason: "head_already_validated",
        evidence: { head_sha: head_sha }
      )
    end

    def self.name = "validated_landing"
  end
end
