class LocalToolCall < ApplicationRecord
  POLL_INTERVAL = 0.5.seconds
  TIMEOUT = 120.seconds

  belongs_to :local_daemon_session

  def wait_for_result
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT

    loop do
      reload
      return { result: result } if completed_at.present? && error.nil?
      return { error: error } if completed_at.present? && error.present?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(POLL_INTERVAL)
    end

    { error: "Timed out waiting for daemon response." }
  end
end
