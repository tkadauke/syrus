class WorkflowVisualEvidence < ApplicationRecord
  include HasConfigurableRetention

  configurable_retention setting_key: :draft_visual_evidence_retention_days, unit: :days

  belongs_to :workflow
  belongs_to :run
  belongs_to :step
  has_one_attached :image

  validates :stable_id, :sequence, :status, :captured_at, :content_digest, presence: true
  validates :stable_id, uniqueness: true
  validates :sequence, uniqueness: { scope: :run_id }
  validates :status, inclusion: { in: %w[draft submitted] }

  scope :prunable, -> { where(status: "draft") }

  before_validation { self.stable_id ||= SecureRandom.uuid }

  def promote!
    update!(status: "submitted")
  end
end
