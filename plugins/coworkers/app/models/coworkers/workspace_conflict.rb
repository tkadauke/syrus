class Coworkers::WorkspaceConflict < ApplicationRecord
  self.table_name = "coworker_workspace_conflicts"

  belongs_to :chat_session
  belongs_to :repository

  validates :source_branch, :state, :files, :versions, presence: true
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :state, inclusion: { in: %w[pending resolved failed] }

  scope :active, -> { where(state: "pending") }
end
