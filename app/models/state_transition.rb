class StateTransition < ApplicationRecord
  # Subject is one of Job / Workflow / Step / Run. Polymorphic
  # because the audit shape is uniform across all four — same
  # questions about every record (when did it move, why, who).
  belongs_to :subject, polymorphic: true
  belongs_to :user, optional: true
  belongs_to :run, optional: true

  SOURCES = %w[
    aasm
    propagate
    reconciler
    operator
    system
  ].freeze

  validates :from_state, :to_state, :source, presence: true
  validates :source, inclusion: { in: SOURCES }

  # Seed an empty hash on new records — MySQL 8 disallows defaults
  # on JSON columns, so the migration left the column nullable.
  # SmartFolder + Whiteboard + Step.details use the same pattern.
  after_initialize :default_metadata, if: :new_record?

  scope :for_subject, ->(subject) {
    where(subject_type: subject.class.polymorphic_name, subject_id: subject.id)
  }
  scope :recent, -> { order(created_at: :desc) }

  # Run a block with a specific source tag. Any AASM transition that
  # fires inside the block records this source instead of the default
  # "aasm" — propagation hooks, the reconciler, and operator controllers
  # use this to annotate their lifts.
  def self.with_source(source, user: nil, reason: nil, reason_key: nil, metadata: nil)
    source = source.to_s
    raise ArgumentError, "unknown source: #{source}" unless SOURCES.include?(source)

    prior_source          = Thread.current[:state_transition_source]
    prior_user            = Thread.current[:state_transition_user]
    prior_reason_key      = Thread.current[:state_transition_reason_key]
    prior_reason_metadata = Thread.current[:state_transition_reason_metadata]
    Thread.current[:state_transition_source] = source
    Thread.current[:state_transition_user]   = user
    Thread.current[:state_transition_reason_key] = (reason_key || reason)&.to_s
    Thread.current[:state_transition_reason_metadata] = metadata.to_h
    yield
  ensure
    Thread.current[:state_transition_source]          = prior_source
    Thread.current[:state_transition_user]            = prior_user
    Thread.current[:state_transition_reason_key]      = prior_reason_key
    Thread.current[:state_transition_reason_metadata] = prior_reason_metadata
  end

  def self.current_source
    Thread.current[:state_transition_source] || "aasm"
  end

  def self.current_user
    Thread.current[:state_transition_user]
  end

  def self.current_reason_key
    Thread.current[:state_transition_reason_key]
  end

  def self.current_reason_metadata
    Thread.current[:state_transition_reason_metadata].to_h
  end

  # Captured by Concerns::RecordsStateTransitions for any in-flight
  # Run set by RunJob — gives us the "which Run was active when this
  # propagation happened" cross-link.
  def self.current_run_id
    Thread.current[:syrus_current_run]&.id
  end

  def self.reason_key_for(subject)
    explicit = current_reason_key.presence
    return explicit if explicit

    inferred_transition_metadata_for(subject)["reason_key"].presence
  end

  def self.transition_metadata_for(subject)
    inferred_transition_metadata_for(subject).merge(current_reason_metadata).compact
  end

  def self.inferred_transition_metadata_for(subject)
    case subject
    when Job
      {
        "reason_key" => first_present(
          subject.closure_reason,
          subject.needs_attention_reason,
          subject.landing_failure_reason,
          subject.runaway_protection,
          subject.invalidation_reason,
          subject.triaging_reason
        ),
        "closure_reason" => subject.closure_reason,
        "needs_attention_reason" => subject.needs_attention_reason,
        "landing_failure_reason" => subject.landing_failure_reason,
        "runaway_protection" => subject.runaway_protection,
        "invalidation_reason" => subject.invalidation_reason,
        "triaging_reason" => subject.triaging_reason,
        "landing_queue_blocked_reason" => compact_reason_hash(subject.landing_queue_blocked_reason)
      }
    when Workflow
      {
        "reason_key" => first_present(
          subject.failure_reason,
          subject.artifact("failure_reason"),
          subject.artifact("start_blocked_reason"),
          subject.artifact("start_cancelled_reason"),
          subject.artifact("cancelled_reason"),
          subject.artifact("pause_reason")
        ),
        "failure_reason" => subject.failure_reason,
        "artifact_failure_reason" => subject.artifact("failure_reason"),
        "start_blocked_reason" => subject.artifact("start_blocked_reason"),
        "start_cancelled_reason" => subject.artifact("start_cancelled_reason"),
        "cancelled_reason" => subject.artifact("cancelled_reason"),
        "pause_reason" => subject.artifact("pause_reason"),
        "trigger_kind" => subject.trigger_kind
      }
    when Step
      details = subject.details.to_h
      {
        "reason_key" => first_present(subject.cancellation_reason, details["skip_reason"], details["failure_code"]),
        "cancellation_reason" => subject.cancellation_reason,
        "skip_reason" => details["skip_reason"],
        "failure_code" => details["failure_code"],
        "step_kind" => subject.kind
      }
    when Run
      classification = subject.run_failure_classification
      {
        "reason_key" => classification&.classification,
        "failure_classification" => classification&.classification,
        "failure_reason" => classification&.reason,
        "step_kind" => subject.step&.kind,
        "trigger_kind" => subject.trigger_kind
      }
    else
      {}
    end.compact
  rescue StandardError
    {}
  end

  def self.first_present(*values)
    values.find { |value| value.present? }&.to_s
  end
  private_class_method :first_present

  def self.compact_reason_hash(value)
    hash = value.to_h
    return if hash.blank?

    hash.slice("key", :key, "message", :message)
  end
  private_class_method :compact_reason_hash

  private

  def default_metadata
    self.metadata ||= {}
  end
end
