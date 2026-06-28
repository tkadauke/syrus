class TerminalSessionJob < ApplicationJob
  queue_as :chat

  def perform(terminal_session_id)
    session = TerminalSession.find(terminal_session_id)
    return if session.finished?

    TerminalRelay.new(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([])
    ).run
  end
end
