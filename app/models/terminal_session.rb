class TerminalSession < ApplicationRecord
  include TracksFinishedAt

  OUTCOMES = %w[ exited killed orphaned ].freeze

  belongs_to :user
  belongs_to :workflow, optional: true

  before_validation :default_auth_token, on: :create

  validates :name, :working_directory, :auth_token, :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES, allow_nil: true }

  def relay_ready? = relay_address.present?

  private

  def default_auth_token
    self.auth_token ||= SecureRandom.hex(32)
  end
end
