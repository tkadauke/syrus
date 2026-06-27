class TerminalSessionJob < ApplicationJob
  queue_as :default

  def perform(session_id)
    TerminalSession.find(session_id)
  end
end
