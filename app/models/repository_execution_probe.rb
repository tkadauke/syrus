class RepositoryExecutionProbe < ApplicationRecord
  STATUSES = %w[queued running succeeded warning failed blocked].freeze

  belongs_to :repository
  belongs_to :requested_by, class_name: "User"

  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :in_flight, -> { where(in_flight: true) }

  before_validation :sync_in_flight

  Claim = Data.define(:probe, :created)

  def self.claim!(repository:, requested_by:)
    existing = in_flight.find_by(repository:)
    return Claim.new(probe: existing, created: false) if existing

    Claim.new(probe: create!(repository:, requested_by:, result: {}), created: true)
  rescue ActiveRecord::RecordNotUnique
    Claim.new(probe: in_flight.find_by!(repository:), created: false)
  end

  def terminal? = status.in?(%w[succeeded warning failed blocked])
  def implementation_blocking? = blocked? && !warning_override?

  STATUSES.each { |value| define_method("#{value}?") { status == value } }

  private

  def sync_in_flight
    self.in_flight = terminal? ? nil : true
  end
end
