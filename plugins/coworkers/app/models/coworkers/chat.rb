class Coworkers::Chat < ApplicationRecord
  self.table_name = "coworker_chats"
  ROLES = %w[main side].freeze

  belongs_to :coworker, inverse_of: :coworker_chats
  belongs_to :chat_session
  validates :chat_session_id, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :coworker_id, uniqueness: { conditions: -> { where(role: "main") } }, if: :main?
  validate :chat_and_coworker_share_owner

  def main? = role == "main"

  def unsaved_workspace?
    unsaved_workspace_branch.present?
  end

  def unsaved_workspace_json
    return unless unsaved_workspace?

    {
      branch: unsaved_workspace_branch, path: unsaved_workspace_path,
      last_error: unsaved_workspace_error, failure_kind: unsaved_workspace_failure_kind,
      operation: unsaved_workspace_operation,
      first_failed_at: unsaved_workspace_first_failed_at&.iso8601,
      last_failed_at: unsaved_workspace_last_failed_at&.iso8601,
      attempt_count: unsaved_workspace_attempt_count.to_i,
      retry_exhausted: unsaved_workspace_retry_exhausted_at.present?
    }
  end

  private

  def chat_and_coworker_share_owner
    return if coworker.nil? || chat_session.nil?
    return if coworker.owner_user_id == chat_session.user_id

    errors.add(:chat_session, "must be owned by the coworker's owner")
  end
end
