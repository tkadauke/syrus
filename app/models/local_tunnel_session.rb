class LocalTunnelSession < ApplicationRecord
  belongs_to :user
  belongs_to :chat_session, optional: true

  STATUSES = %w[connected paused disconnected].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[connected paused]) }
  scope :connected, -> { where(status: "connected") }

  def disconnect!
    update!(status: "disconnected", disconnected_at: Time.current)
  end

  def pause!
    update!(status: "paused")
  end

  def reconnect!(repo_slug:, branch:)
    update!(
      repo_slug: repo_slug,
      branch: branch,
      status: "connected",
      connected_at: Time.current,
      disconnected_at: nil
    )
  end
end
