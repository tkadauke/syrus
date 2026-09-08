module RuntimeTerminal
  class Provider
    include Syrus::Plugin::RuntimeSessionProvider

    class << self
      def provider_key = "cli_tui"
      def display_name = "Terminal"

      def detect(_repository, _config)
        false
      end

      def capabilities(_repository, _config)
        {
          stream: "none",
          input: [],
          inspect: [ "none" ],
          build: [ "none" ],
          artifacts: [ "logs" ]
        }
      end
    end

    def start_session(workspace_ref, config)
      config = config.to_h.symbolize_keys
      runtime_session = config.fetch(:runtime_session)
      chat_session = config.fetch(:chat_session)

      terminal_session = Terminal::Session.create!(
        user: chat_session.user,
        workflow: nil,
        name: config[:terminal_name].presence || "Runtime Terminal",
        working_directory: workspace_ref,
        started_at: Time.current
      )
      RuntimeTerminal::SessionLink.create!(
        runtime_session: runtime_session,
        terminal_session: terminal_session
      )
      TerminalSessionJob.perform_later(terminal_session.id)

      { terminal_session_id: terminal_session.id }
    end

    def build_or_reload(_session_id, _options)
      not_supported("build_or_reload")
    end

    def launch(_session_id, _options)
      not_supported("launch")
    end

    def snapshot(_session_id, _options)
      not_supported("snapshot")
    end

    def inspect(session_id = nil, _options = nil)
      raise NotImplementedError, "#{self.class}#inspect requires a session_id" if session_id.nil?

      not_supported("inspect")
    end

    def input(_session_id, _event)
      not_supported("input")
    end

    def logs(_session_id, cursor, _options)
      { entries: [], cursor: cursor.to_i }
    end

    def stop_session(session_id)
      terminal_session = terminal_session_for(session_id)
      terminal_session.update!(finished_at: Time.current, outcome: "killed") if terminal_session.running?

      true
    end

    private

    def terminal_session_for(session_id)
      RuntimeTerminal::SessionLink.find_by!(runtime_session_id: runtime_session_id(session_id)).terminal_session
    end

    def runtime_session_id(session_id)
      session_id.is_a?(RuntimeSession) ? session_id.id : session_id
    end

    def not_supported(operation)
      { error: "not_yet_supported", message: "runtime_terminal #{operation} is not supported yet" }
    end
  end
end
