module Adjudicators
  # `.syrus.yml`'s `grade.failures: allow_inherited`, stated as a rung-0
  # adjudicator.
  #
  # A grader that was already failing on the base SHA is not this workflow's
  # problem. MainBranchFailureClassifier has always been able to tell; what it
  # could not do was say so in a form anything other than its own caller
  # understood.
  module InheritedGraderFailure
    def self.adjudicate(problem:, workflow: nil, step: nil, **)
      return Adjudication.inconclusive(adjudicator: name) unless problem&.code == "grader_failure"
      return Adjudication.inconclusive(adjudicator: name) unless workflow

      steps = Array(step || failed_grader_steps(workflow))
      return Adjudication.inconclusive(adjudicator: name) if steps.empty?

      result = MainBranchFailureClassifier.call(workflow: workflow, failed_grader_steps: steps)
      return Adjudication.inconclusive(adjudicator: name, reason: "not_inherited") unless result.inherited?

      Adjudication.dismiss(
        adjudicator: name,
        reason: "grader_already_failing_on_base",
        evidence: { inherited_names: result.inherited_names, new_names: result.new_names }
      )
    end

    def self.failed_grader_steps(workflow)
      workflow.steps.select { |candidate| candidate.kind == "grader" && candidate.state == "failed" }
    end

    def self.name = "inherited_grader_failure"
  end
end
