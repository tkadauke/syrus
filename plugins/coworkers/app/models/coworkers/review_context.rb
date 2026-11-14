class Coworkers::ReviewContext < ApplicationRecord
  self.table_name = "coworker_review_contexts"

  STATES = %w[prepared persisted failed tombstoned].freeze

  belongs_to :run
  belongs_to :review_evidence
  belongs_to :coworker, class_name: "Coworkers::Coworker", inverse_of: :review_contexts

  encrypts :exact_context
  serialize :exact_context, coder: JSON

  validates :run_id, :review_evidence_id, uniqueness: true
  validates :persistence_state, inclusion: { in: STATES }
  validates :manifest, :exact_context, :workspace_path, presence: true

  scope :retention_candidates, -> { where.not(persistence_state: "tombstoned") }

  before_destroy :remove_live_workspace

  def tombstone!
    update!(exact_context: "[tombstoned]", workspace_path: "[tombstoned]",
            persistence_state: "tombstoned", tombstoned_at: Time.current)
  end

  private

  def remove_live_workspace
    Coworkers::ReviewWorkspace.remove!(self) unless persistence_state == "tombstoned"
  end
end
