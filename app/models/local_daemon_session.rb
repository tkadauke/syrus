class LocalDaemonSession < ApplicationRecord
  HEARTBEAT_TIMEOUT = 45.seconds

  belongs_to :chat_session
  belongs_to :user

  has_many :tool_calls, class_name: "LocalToolCall", dependent: :destroy

  before_validation :default_auth_token, on: :create

  validates :auth_token, presence: true, uniqueness: true

  scope :connected, -> { where(disconnected_at: nil) }
  scope :disconnected, -> { where.not(disconnected_at: nil) }

  def connected? = disconnected_at.nil?
  def disconnected? = !connected?

  def heartbeat_stale?
    # Use last_heartbeat_at when available; fall back to updated_at so a daemon
    # that never responds to pings is eventually considered stale.
    baseline = last_heartbeat_at || updated_at
    baseline < HEARTBEAT_TIMEOUT.ago
  end

  def pending_tool_calls
    tool_calls.where(state: "pending").order(:created_at)
  end

  def mark_connected!(repo:, branch:)
    now = Time.current
    update!(
      daemon_repo: repo,
      daemon_branch: branch,
      last_heartbeat_at: now,
      disconnected_at: nil
    )
    chat_session.update!(
      daemon_connected: true,
      daemon_repo: repo,
      daemon_branch: branch
    )
    chat_session.broadcast_daemon_status("connected", repo: repo, branch: branch)
  end

  def mark_disconnected!
    return if disconnected?

    update!(disconnected_at: Time.current)
    chat_session.update!(daemon_connected: false)
    chat_session.broadcast_daemon_status("disconnected")
  end

  def record_heartbeat!
    update!(last_heartbeat_at: Time.current)
  end

  private

  def default_auth_token
    self.auth_token ||= SecureRandom.hex(32)
  end
end
