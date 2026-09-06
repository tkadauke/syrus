class WorkEngineReconcilerActivityEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETAIN_AFTER = 7.days

  EVENT_TYPES = %w[run_started issues_detected repair_planned repair_executed run_finished run_failed].freeze
  SEVERITIES = %w[info warn error alarm].freeze

  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :run, optional: true

  attribute :details, :json, default: -> { {} }

  before_validation { self.details ||= {} }

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :source, :message, :occurred_at, presence: true

  before_update { raise ActiveRecord::ReadOnlyRecord, "WorkEngineReconcilerActivityEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "WorkEngineReconcilerActivityEvent is append-only" unless destroyed_by_association }

  scope :prunable, -> { where("occurred_at < ?", RETAIN_AFTER.ago) }

  def self.record!(event_type:, source:, message:, severity: "info", occurred_at: Time.current, job_id: nil, workflow_id: nil, step_id: nil, run_id: nil, issue_kind: nil, repair_action: nil, repair_status: nil, details: {})
    attrs = {
      "event" => "syrus.work_engine.reconciler_activity",
      "event_type" => event_type,
      "source" => source.to_s,
      "severity" => severity.to_s,
      "job_id" => job_id,
      "workflow_id" => workflow_id,
      "step_id" => step_id,
      "run_id" => run_id,
      "issue_kind" => issue_kind&.to_s,
      "repair_action" => repair_action&.to_s,
      "repair_status" => repair_status&.to_s,
      "message" => message.to_s,
      "details" => details || {},
      "occurred_at" => occurred_at.iso8601(6)
    }.compact

    # Buffered, not written through. The reconciler emits tens of thousands of
    # these a day, and flushing per event meant one INSERT plus one SELECT
    # apiece -- the single largest source of one-row writes in the system.
    # Readers (Admin::ReconcilerActivityPayload) flush before querying, so
    # nothing observable is lost; callers here ignore the return value.
    Observability::EventSink.append(kind: :work_engine_reconciler_activity, event: attrs)
    attrs
  rescue StandardError => e
    Rails.logger.warn("[WorkEngineReconcilerActivityEvent] record failed: #{e.class}: #{e.message}")
    nil
  end

  def self.from_event_hash(event)
    attrs = event.to_h
    {
      event_type: attrs["event_type"],
      source: attrs["source"],
      severity: attrs["severity"] || "info",
      job_id: attrs["job_id"],
      workflow_id: attrs["workflow_id"],
      step_id: attrs["step_id"],
      run_id: attrs["run_id"],
      issue_kind: attrs["issue_kind"],
      repair_action: attrs["repair_action"],
      repair_status: attrs["repair_status"],
      message: attrs["message"],
      details: normalized_event_json(attrs["details"]),
      occurred_at: parse_event_time(attrs["occurred_at"]) || Time.current,
      created_at: Time.current,
      updated_at: Time.current
    }.compact
  end

  def as_event_hash
    {
      "event" => "syrus.work_engine.reconciler_activity",
      "event_type" => event_type,
      "source" => source,
      "severity" => severity,
      "job_id" => job_id,
      "workflow_id" => workflow_id,
      "step_id" => step_id,
      "run_id" => run_id,
      "issue_kind" => issue_kind,
      "repair_action" => repair_action,
      "repair_status" => repair_status,
      "message" => message,
      "details" => details,
      "occurred_at" => occurred_at&.iso8601(6)
    }.compact
  end

  def self.as_recent_event_hashes(limit:)
    recent_first.limit(limit).map(&:as_event_hash)
  end
end
