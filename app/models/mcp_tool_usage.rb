class McpToolUsage < ApplicationRecord
  SURFACES = %w[ workflow chat ].freeze
  STATUSES = %w[ started completed failed ].freeze
  ERROR_SUMMARY_MAX_LENGTH = 512

  belongs_to :user, optional: true
  belongs_to :repository, optional: true
  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true
  belongs_to :chat_session, optional: true

  validates :surface, :raw_tool_name, :tool_name, :normalized_tool_name, :status, presence: true
  validates :surface, inclusion: { in: SURFACES }
  validates :status, inclusion: { in: STATUSES }

  scope :in_window, ->(started_at, ended_at) {
    where("COALESCE(started_at, created_at) >= ? AND COALESCE(started_at, created_at) < ?", started_at, ended_at)
  }
end
