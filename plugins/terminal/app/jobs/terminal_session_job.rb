class TerminalSessionJob < ApplicationJob
  queue_as :chat

  def perform(terminal_session_id)
    session = Terminal::Session.find(terminal_session_id)
    return if session.finished?

    Terminal::Relay.new(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([])
    ).run
  end
end
