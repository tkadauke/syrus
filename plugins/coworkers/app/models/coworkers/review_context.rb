class Coworkers::ReviewContext < ApplicationRecord
  self.table_name = "coworker_review_contexts"

  STATES = %w[prepared persisted failed tombstoned].freeze

  belongs_to :run
  # Opaque reference to generic review evidence: no database foreign key, so
  # evidence purges and plugin removal never block each other. The immutable
  # `evidence_snapshot` carries everything the journal needs from evidence.
  belongs_to :review_evidence, optional: true
  belongs_to :coworker, class_name: "Coworkers::Coworker"

  encrypts :exact_context
  serialize :exact_context, coder: JSON

  validates :run_id, :review_evidence_id, uniqueness: true
  validates :idempotency_key, uniqueness: true, allow_nil: true
  validates :persistence_state, inclusion: { in: STATES }
  validates :manifest, :exact_context, :workspace_path, presence: true

  scope :retention_candidates, -> { where.not(persistence_state: "tombstoned") }

  def self.idempotency_key_for(evidence_id) = "coworker-review-context:#{evidence_id}"

  def tombstone!
    update!(exact_context: "[tombstoned]", workspace_path: "[tombstoned]",
            persistence_state: "tombstoned", tombstoned_at: Time.current)
  end
end
