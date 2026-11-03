class TerminalSessionJob < ApplicationJob
  queue_as :chat

  def perform(terminal_session_id)
    session = Terminal::Session.find(terminal_session_id)
    return if session.finished?

    # The working directory (e.g. a cleaned-up workflow workspace) can vanish
    # before the relay starts; PTY.spawn would raise Errno::ENOENT on chdir.
    unless Dir.exist?(session.working_directory.to_s)
      session.update!(finished_at: Time.current, outcome: "exited")
      return
    end

    session.update!(relay_started_at: Time.current)

    Terminal::Relay.new(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([])
    ).run
  end
end
