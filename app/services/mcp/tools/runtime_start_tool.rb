require "mcp"

module Mcp::Tools
  class RuntimeStartTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_start"

    description <<~DESC
      Start a new Runtime Session (DOC-17) for this Coding Mode chat's
      repository -- a live dev server/app/process the agent and operator can
      both observe and (with a control lease) interact with. Auto-detects a
      provider from the repository checkout when `provider` is omitted
      (currently "browser" is the only registered provider). The first
      session started for a chat becomes its primary session.
    DESC

    input_schema(
      properties: {
        provider: {
          type: "string",
          description: "Runtime session provider key (e.g. \"browser\"). Auto-detected from the repository checkout when omitted."
        },
        name: {
          type: "string",
          description: "Optional display name for the session. Defaults to the provider's display name."
        },
        options: {
          type: "object",
          description: "Provider-specific start options (e.g. { \"port\": 3001 } for the browser provider)."
        }
      }
    )

    class << self
      def call(provider: nil, name: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        repository = resolve_repository(chat_session)
        return Mcp::Tools.invalid("this chat has no attached repository") unless repository

        workspace_path = ChatWorkspace.repo_path_for(chat_session, repository).to_s
        unless File.directory?(workspace_path)
          return Mcp::Tools.invalid("no Coding Mode checkout found for this chat yet; the workspace may still be preparing")
        end

        config = normalize_options(options).merge(workspace_path: workspace_path)
        provider_class, error = resolve_provider_class(provider, repository, config)
        return error if error

        runtime_session = RuntimeSession.create!(
          repository: repository,
          chat_session: chat_session,
          workspace_ref: workspace_path,
          provider_key: provider_class.provider_key,
          display_name: name.presence || provider_class.display_name,
          capabilities: provider_class.capabilities(repository, config),
          primary: !chat_session.runtime_sessions.active.exists?,
          state: "starting"
        )

        begin
          result = provider_class.new.start_session(workspace_path, config)
          runtime_session.update!(state: "running", metadata: runtime_session.metadata.merge(result.to_h.deep_stringify_keys))
        rescue StandardError => e
          runtime_session.update!(state: "failed", last_error: "#{e.class}: #{e.message}")
          return Mcp::Tools.invalid("failed to start runtime session: #{e.message}")
        end

        Mcp::Tools.success(runtime_session_payload(runtime_session))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def resolve_provider_class(provider, repository, config)
        if provider.present?
          [ RuntimeSessionProviders.for(provider), nil ]
        else
          detected = RuntimeSessionProviders.detect_for(repository, config)
          return [ nil, Mcp::Tools.invalid("no runtime session provider detected for this repository; specify `provider`.") ] unless detected

          [ detected, nil ]
        end
      rescue RuntimeSessionProviders::ConfigurationError => e
        [ nil, Mcp::Tools.invalid(e.message) ]
      end
    end
  end
end
