class WorkflowSourceSnapshot < ApplicationRecord
  belongs_to :workflow
  belongs_to :creator_step, class_name: "Step"

  validates :source_sha, :source_ref, :published_at, presence: true
  validates :source_sha, uniqueness: { scope: :workflow_id }
  validate :creator_step_belongs_to_workflow
  validate :tree_identity_present

  scope :current_first, -> { order(published_at: :desc, id: :desc) }

  def self.current_for(workflow)
    where(workflow: workflow).current_first.first
  end

  private

  def creator_step_belongs_to_workflow
    return if workflow_id.blank? || creator_step.blank?
    return if creator_step.workflow_id == workflow_id

    errors.add(:creator_step, "must belong to the snapshot workflow")
  end

  def tree_identity_present
    return if tree_sha.present? || source_fingerprint.present?

    errors.add(:base, "tree_sha or source_fingerprint must be present")
  end
end
