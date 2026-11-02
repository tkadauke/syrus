module RuntimeTerminal
  class Provider
    include Syrus::Plugin::RuntimeSessionProvider

    RELAY_ADDRESS_TIMEOUT = 10.seconds
    RELAY_ADDRESS_POLL_INTERVAL = 0.2.seconds

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
          inspect: %w[screen scrollback],
          build: [ "none" ],
          artifacts: %w[screenshots logs]
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

      def replace_relay_client!(runtime_session_id, terminal_session)
        relay_clients_lock.synchronize do
          previous = relay_clients.delete(runtime_session_id.to_i)
          generation = previous&.screen_generation.to_i
          previous&.close
          relay_clients[runtime_session_id.to_i] = RelayClient.new(terminal_session, generation: generation)
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

    def snapshot(session_id, options = {})
      runtime_session = runtime_session_for(session_id)
      terminal_session = relay_ready_terminal_session_for(runtime_session)
      options = options.to_h.symbolize_keys
      screen = with_fresh_relay_client(runtime_session, terminal_session, &:capture_screen)
      captured_at = Time.current
      bytes = Renderer.new(screen).png
      checkpoint = options[:checkpoint_label].presence
      title = checkpoint ? "Terminal — #{checkpoint}" : "Terminal screenshot"
      document = ArtifactSink.new(runtime_session).capture(bytes: bytes, title: title)

      metadata = {
        runtime_session_id: runtime_session.id,
        screen_generation: screen.fetch(:generation),
        rows: screen.fetch(:rows),
        columns: screen.fetch(:cols),
        captured_at: captured_at.iso8601,
        checkpoint_label: checkpoint
      }.compact
      {
        kind: "terminal_screenshot",
        artifact_type: "screenshot",
        title: title,
        content_type: "image/png",
        viewport: { width: screen.fetch(:cols), height: screen.fetch(:rows) },
        document_id: document.id,
        metadata: metadata,
        latest_frame_url: runtime_session.latest_frame_url,
        latest_frame_at: runtime_session.latest_frame_at&.iso8601
      }.merge(metadata)
    end

    def inspect(session_id = nil, options = nil)
      raise NotImplementedError, "#{self.class}#inspect requires a session_id" if session_id.nil?

      runtime_session = runtime_session_for(session_id)
      terminal_session = relay_ready_terminal_session_for(runtime_session)
      options = options.to_h.symbolize_keys
      mode = options.fetch(:mode, "screen").to_s
      result = with_fresh_relay_client(runtime_session, terminal_session) do |client|
        inspect_client(client, mode, options)
      end
      result
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

      terminal_session = relay_ready_terminal_session_for(runtime_session)
      with_fresh_relay_client(runtime_session, terminal_session) do |client|
        client.input(event)
      end
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

    def inspect_client(client, mode, options)
      if mode == "scrollback"
        scrollback = client.inspect_scrollback
        return { kind: "terminal_scrollback", scrollback: scrollback, bytes: scrollback.bytesize }
      end
      raise ArgumentError, "unsupported terminal inspection mode #{mode.inspect}" unless mode == "screen"

      client.inspect_screen(
        after_generation: options[:after_generation],
        wait_for_change: ActiveModel::Type::Boolean.new.cast(options[:wait_for_change]),
        wait_for_text: options[:wait_for_text],
        quiet_seconds: duration_seconds(options, :quiet_ms),
        timeout_seconds: duration_seconds(options, :timeout_ms, default: wait_requested?(options) ? 5_000 : 0),
        include_styles: ActiveModel::Type::Boolean.new.cast(options[:include_styles])
      )
    end

    def duration_seconds(options, key, default: 0)
      Float(options.fetch(key, default)) / 1_000
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{key} must be a number of milliseconds"
    end

    def wait_requested?(options)
      options[:after_generation].present? || options[:wait_for_text].present? ||
        ActiveModel::Type::Boolean.new.cast(options[:wait_for_change]) || options[:quiet_ms].present?
    end

    def runtime_session_for(session_id)
      return session_id if session_id.is_a?(RuntimeSession)

      RuntimeSession.find(session_id)
    end

    def terminal_session_for(runtime_session)
      RuntimeTerminal::SessionLink.find_by!(runtime_session_id: runtime_session.id).terminal_session
    end

    def relay_ready_terminal_session_for(runtime_session)
      terminal_session = terminal_session_for(runtime_session)
      deadline = Time.current + RELAY_ADDRESS_TIMEOUT

      until terminal_session.relay_ready? || Time.current > deadline
        sleep RELAY_ADDRESS_POLL_INTERVAL
        terminal_session.reload
      end

      terminal_session
    end

    def relay_client_for(runtime_session, terminal_session)
      self.class.relay_client_for(runtime_session.id, terminal_session)
    end

    def with_fresh_relay_client(runtime_session, terminal_session)
      client = relay_client_for(runtime_session, terminal_session)
      result = yield(client)
      return result unless client.closed?

      yield(self.class.replace_relay_client!(runtime_session.id, terminal_session))
    rescue RelayClient::ConnectionError
      yield(self.class.replace_relay_client!(runtime_session.id, terminal_session))
    end

    def not_supported(operation)
      { error: "not_yet_supported", message: "runtime_terminal #{operation} is not supported yet" }
    end
  end
end
