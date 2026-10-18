class RepositoryExecutionProbe < ApplicationRecord
  STATUSES = %w[queued running succeeded warning failed blocked].freeze

  belongs_to :repository
  belongs_to :requested_by, class_name: "User"

  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def terminal? = status.in?(%w[succeeded warning failed blocked])
  def implementation_blocking? = blocked? && !warning_override?

  STATUSES.each { |value| define_method("#{value}?") { status == value } }
end
