class DesignDocCollaborator < ApplicationRecord
  ROLES = %w[viewer editor].freeze

  belongs_to :design_doc
  belongs_to :user
  belongs_to :added_by_user, class_name: "User", optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :design_doc_id }
  validate :owner_is_not_explicit_collaborator

  private

  def owner_is_not_explicit_collaborator
    return if design_doc.nil? || user_id.blank?
    return if design_doc.owner_user_id != user_id

    errors.add(:user, "is already the owner")
  end
end
