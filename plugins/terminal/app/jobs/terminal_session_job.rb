class TerminalSessionJob < ApplicationJob
  queue_as :chat

  def perform(terminal_session_id)
    session = Terminal::Session.find(terminal_session_id)
    return if session.finished?

    # A working directory that no longer exists would make PTY.spawn raise
    # Errno::ENOENT on every retry; close the session instead. The update is
    # conditional so a concurrent kill keeps its "killed" outcome.
    unless Dir.exist?(session.working_directory.to_s)
      Terminal::Session.where(id: session.id, finished_at: nil)
                       .update_all(finished_at: Time.current, outcome: "exited")
      return
    end

    session.update!(relay_started_at: Time.current)

    provider_env = RuntimeSessionProviders.all.lazy.filter_map do |provider|
      provider.new.environment_for_terminal(session)
    end.first || {}

    Terminal::Relay.new(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([]).merge(provider_env)
    ).run
  end
end
