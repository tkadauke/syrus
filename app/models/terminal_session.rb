class TerminalSession < ApplicationRecord
  OUTCOMES = %w[ exited killed orphaned ].freeze

  belongs_to :user
  belongs_to :workflow, optional: true

  before_validation :default_auth_token, on: :create

  validates :name, :working_directory, :auth_token, :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES, allow_nil: true }

  scope :running, -> { where(finished_at: nil) }
  scope :finished, -> { where.not(finished_at: nil) }

  def running? = finished_at.nil?
  def finished? = !running?

  def relay_ready? = relay_address.present?

  private

  def default_auth_token
    self.auth_token ||= SecureRandom.hex(32)
  end
end
