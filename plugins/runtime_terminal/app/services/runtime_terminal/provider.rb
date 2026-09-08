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
          input: %w[keyboard stdin pointer resize],
          inspect: [ "scrollback" ],
          build: [ "none" ],
          artifacts: [ "logs" ]
        }
      end

      def reset_relay_clients!
        relay_clients_lock.synchronize do
          relay_clients.each_value(&:close)
          relay_clients.clear
        end
      end

      def close_relay_client!(runtime_session_id)
        relay_clients_lock.synchronize { relay_clients.delete(runtime_session_id.to_i) }&.close
      end

      def relay_client_for(runtime_session_id, terminal_session)
        relay_clients_lock.synchronize do
          relay_clients[runtime_session_id.to_i] ||= RelayClient.new(terminal_session)
        end
      end

      private

      def relay_clients
        @relay_clients ||= {}
      end

      def relay_clients_lock
        @relay_clients_lock ||= Mutex.new
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

      runtime_session = runtime_session_for(session_id)
      terminal_session = terminal_session_for(runtime_session)
      scrollback = relay_client_for(runtime_session, terminal_session).inspect_scrollback

      { kind: "terminal_scrollback", scrollback: scrollback, bytes: scrollback.bytesize }
    end

    def input(session_id, event)
      runtime_session = runtime_session_for(session_id)
      event = event.to_h.symbolize_keys
      lease = runtime_session.active_agent_input_lease

      unless lease
        RuntimeControlLease.audit_input_rejected!(runtime_session: runtime_session, event: event)
        return {
          error: "lease_required",
          message: "the agent must hold an active input lease before sending input events"
        }
      end

      terminal_session = terminal_session_for(runtime_session)
      relay_client_for(runtime_session, terminal_session).input(event)
      lease.record_input!(event)

      { delivered: true }
    rescue RelayClient::ConnectionError, RelayClient::UnsupportedInput => e
      { error: e.class.name.demodulize.underscore, message: e.message }
    end

    def logs(_session_id, cursor, _options)
      { entries: [], cursor: cursor.to_i }
    end

    def stop_session(session_id)
      runtime_session = runtime_session_for(session_id)
      self.class.close_relay_client!(runtime_session.id)
      terminal_session = terminal_session_for(runtime_session)
      terminal_session.update!(finished_at: Time.current, outcome: "killed") if terminal_session.running?

      true
    end

    private

    def runtime_session_for(session_id)
      return session_id if session_id.is_a?(RuntimeSession)

      RuntimeSession.find(session_id)
    end

    def terminal_session_for(runtime_session)
      RuntimeTerminal::SessionLink.find_by!(runtime_session_id: runtime_session.id).terminal_session
    end

    def relay_client_for(runtime_session, terminal_session)
      self.class.relay_client_for(runtime_session.id, terminal_session)
    end

    def not_supported(operation)
      { error: "not_yet_supported", message: "runtime_terminal #{operation} is not supported yet" }
    end
  end
end
