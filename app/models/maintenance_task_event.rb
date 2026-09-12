class MaintenanceTaskEvent < ApplicationRecord
  LEVELS = %w[info warning error progress].freeze

  belongs_to :maintenance_task

  validates :level, presence: true, inclusion: { in: LEVELS }
  validates :message, presence: true

  before_validation :default_metadata

  private

  def default_metadata
    self.metadata ||= {}
  end
end
