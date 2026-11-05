class WorkflowWorkspaceEvent < ApplicationRecord
  EVENT_TYPES = %w[created ownership_transferred cleaned_up storage_lost reconstructed].freeze

  belongs_to :workflow

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :actor, presence: true
end
