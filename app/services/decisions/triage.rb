module Decisions
  # The second queue on the decision mechanism (workflow-engine-v3 C3).
  #
  # Bug triage is the same shape as an operator decision -- one problem, its
  # evidence, a small set of typed actions -- but a different audience, a
  # different SLA, and different actions. It is the front door for people who
  # are not the operator.
  #
  # Merging the two would bury the rare important decision under the frequent
  # cheap one, which is the failure mode the whole attention model exists to
  # avoid. So: same mechanism, separate routing.
  #
  # A Job the classifier could not place is the natural first producer. It is
  # not broken, and nothing is stuck -- it simply needs a person to say what it
  # is, which is exactly a triage decision rather than an operator escalation.
  class Triage
    QUEUE = "triage".freeze

    # A classifier that could not decide is not an incident.
    DEFAULT_URGENCY = "low".freeze

    def self.call(...) = new(...).call

    def initialize(job:)
      @job = job
    end

    def call
      return nil unless triageable?

      Decisions::Opener.call(
        problem: problem,
        title: "Needs triage: #{@job.title.presence || @job.slug}",
        summary: @job.triaging_reason.to_s.humanize,
        queue: QUEUE,
        urgency: DEFAULT_URGENCY,
        actions: actions,
        job: @job
      )
    end

    private

    def triageable?
      @job&.state == "triaging" && @job.triaging_reason.to_s == "classifier_uncertain"
    end

    # `validation_or_user_error` is the honest code: the request itself is
    # unclear, which is a problem with the input rather than with Syrus.
    def problem
      Problem[:validation_or_user_error, evidence: {
        triaging_reason: @job.triaging_reason.to_s,
        repository: @job.repository&.slug,
        source_ref: @job.source_ref
      }.compact]
    end

    # Triage actions are about *classifying*, not about repairing -- a
    # different set from the operator queue's, on the same mechanism.
    def actions
      [
        { "action_key" => "close_job_successfully", "label" => "Not actionable",
          "payload" => { "job_id" => @job.id } }
      ].select { |action| known_action?(action["action_key"]) }
    end

    def known_action?(key)
      PendingActions.for(key)
      true
    rescue PendingActions::UnknownAction
      false
    end
  end
end
