module OperatorBriefing
  class WorkflowNotableChange < ApplicationRecord
    self.table_name = "operator_briefing_workflow_notable_changes"

    SEVERITIES = OperatorBriefing::SEVERITIES

    belongs_to :workflow
    belongs_to :job
    belongs_to :repository

    validates :detector_key, :fact_key, :severity, :summary, presence: true
    validates :severity, inclusion: { in: SEVERITIES }

    def self.record_fact!(workflow:, fact:)
      attrs = fact.to_h.deep_stringify_keys
      detector_key = attrs.fetch("key").split(":", 2).first

      record = find_or_initialize_by(workflow: workflow, fact_key: attrs.fetch("key"))
      record.assign_attributes(
        job: workflow.job,
        repository: workflow.job.repository,
        detector_key: detector_key,
        severity: attrs.fetch("severity"),
        summary: attrs.fetch("summary"),
        evidence: attrs["evidence"] || []
      )
      record.save!
      record
    end
  end
end
