class TerminalSessionJob < ApplicationJob
  queue_as :chat

  def perform(terminal_session_id, runtime_session_id: nil, provider_key: nil)
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

    provider_env = if runtime_session_id && provider_key
      runtime_session = RuntimeSession.find(runtime_session_id)
      RuntimeSessionProviders.for(provider_key).new.environment_for_terminal(runtime_session).to_h
    else
      {}
    end

    session.update!(relay_started_at: Time.current)

    Terminal::Relay.new(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([]).merge(provider_env)
    ).run
  rescue RuntimeSessionProviders::ConfigurationError => e
    finish_environment_failure!(session, runtime_session, e)
  end

  private

  def finish_environment_failure!(session, runtime_session, error)
    diagnostic = "#{error.class}: #{error.message}"
    runtime_session&.update!(state: "failed", last_error: diagnostic)
    Terminal::Session.where(id: session.id, finished_at: nil)
                     .update_all(finished_at: Time.current, outcome: "exited")
  end
end
