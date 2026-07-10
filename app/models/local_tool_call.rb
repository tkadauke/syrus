class LocalToolCall < ApplicationRecord
  STATES = %w[ pending dispatched completed failed ].freeze

  # How long to wait for a daemon response before failing the tool call.
  RESPONSE_TIMEOUT = 30.seconds
  RESPONSE_POLL_INTERVAL = 0.1.seconds

  belongs_to :local_daemon_session
  belongs_to :chat_session

  validates :tool_use_id, :tool_name, :state, presence: true
  validates :state, inclusion: { in: STATES }

  after_create_commit :notify_channel

  scope :pending, -> { where(state: "pending") }
  scope :dispatched, -> { where(state: "dispatched") }
  scope :terminal, -> { where(state: %w[completed failed]) }

  def dispatch!
    update!(state: "dispatched", dispatched_at: Time.current)
  end

  def complete!(result:)
    update!(state: "completed", result: result, completed_at: Time.current)
  end

  def fail!(error:)
    update!(state: "failed", error: error, completed_at: Time.current)
  end

  def wait_for_result(timeout: RESPONSE_TIMEOUT)
    deadline = Time.current + timeout
    loop do
      reload
      return result if state == "completed"
      return nil if state == "failed"
      raise LocalToolCall::TimedOut if Time.current > deadline
      sleep RESPONSE_POLL_INTERVAL
    end
  end

  class TimedOut < StandardError; end

  private

  def notify_channel
    ActionCable.server.broadcast(
      "local_daemon_session_#{local_daemon_session_id}_tool_calls",
      { type: "dispatch", tool_call_id: id }
    )
  end
end
