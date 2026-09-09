class WorkflowSourceSnapshot < ApplicationRecord
  belongs_to :workflow
  belongs_to :creator_step, class_name: "Step"

  validates :source_sha, :source_ref, :published_at, presence: true
  validate :has_tree_identity
  validate :creator_step_belongs_to_workflow

  scope :published, -> { where.not(published_at: nil) }
  scope :newest_first, -> { order(published_at: :desc, id: :desc) }

  def tree_identity
    tree_sha.presence || fingerprint.presence
  end

  private

  def has_tree_identity
    return if tree_identity.present?

    errors.add(:base, "tree_sha or fingerprint must be present")
  end

  def creator_step_belongs_to_workflow
    return if creator_step.blank? || workflow.blank?
    return if creator_step.workflow_id == workflow.id

    errors.add(:creator_step, "must belong to the same workflow")
  end
end
