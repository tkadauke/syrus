module OperatorBriefing
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      {
        "operator_briefing.notable_changes_detected" => :on_notable_changes_detected,
        "operator_briefing.review_finding_recorded" => :on_review_finding_recorded
      }
    end

    def self.on_notable_changes_detected(event)
      workflow = Workflow.find_by(id: event[:workflow_id])
      return if workflow.nil?

      Array(event[:facts]).each do |fact|
        WorkflowNotableChange.record_fact!(workflow: workflow, fact: OperatorBriefing::DetectorFact.new(**fact.symbolize_keys))
      end
    end

    def self.on_review_finding_recorded(event)
      workflow = Workflow.find_by(id: event[:workflow_id])
      return if workflow.nil?

      ReviewFinding.record!(
        workflow: workflow,
        step: Step.find_by(id: event[:step_id]),
        run: Run.find_by(id: event[:run_id]),
        review_kind: event[:review_kind],
        iteration: event[:iteration],
        verdict: event[:verdict],
        critique: event[:critique],
        artifacts: event[:artifacts] || [],
        skipped: event[:skipped] || false,
        skip_reason: event[:skip_reason]
      )
    end
  end
end
