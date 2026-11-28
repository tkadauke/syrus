require "mcp"

module Mcp::Tools
  class RuntimeStartTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_start"

    description <<~DESC
      Start a new Runtime Session (DOC-17) for a repository attached to this
      chat -- a live dev server/app/process the agent and operator can both
      observe and (with a control lease) interact with. Select an attached
      product repository with `repository_id` or `repository_slug`; omission
      is allowed only when the chat has one repository. Auto-detects a provider
      from the selected repository checkout when `provider` is omitted. The
      first session started for a chat becomes its primary session.
    DESC

    input_schema(
      properties: {
        provider: {
          type: "string",
          description: "Runtime session provider key (e.g. \"browser\" or \"cli_tui\"). " \
                       "Auto-detected from the repository checkout when omitted."
        },
        repository_id: {
          type: "integer",
          description: "ID of the attached repository to run. Mutually exclusive with repository_slug."
        },
        repository_slug: {
          type: "string",
          description: "Attached repository slug in owner/name form. Mutually exclusive with repository_id."
        },
        name: {
          type: "string",
          description: "Optional display name for the session. Defaults to the provider's display name."
        },
        options: {
          type: "object",
          description: "Provider-specific start options (e.g. { \"port\": 3001 } for browser or " \
                       "{ \"columns\": 100, \"rows\": 30 } for cli_tui)."
        }
      }
    )

    class << self
      def call(provider: nil, repository_id: nil, repository_slug: nil, name: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        repository, repository_error = resolve_runtime_repository(
          chat_session, repository_id: repository_id, repository_slug: repository_slug
        )
        return repository_error if repository_error

        workspace_path = ChatWorkspace.runtime_workspace_for!(chat_session, repository).to_s
        unless workspace_path.present? && File.directory?(workspace_path)
          return Mcp::Tools.invalid("no repository workspace for this chat yet: attach the repository first, or wait for the Coding Mode checkout to finish preparing")
        end

        config = normalize_options(options).merge(chat_session: chat_session, workspace_path: workspace_path)
        provider_class, error = resolve_provider_class(provider, repository, config)
        return error if error

        runtime_session = chat_session.runtime_sessions
          .where(repository: repository, provider_key: provider_class.provider_key, workspace_ref: workspace_path)
          .where.not(state: "stopped").order(created_at: :desc).first
        runtime_session ||= RuntimeSession.create!(
          repository: repository,
          chat_session: chat_session,
          workspace_ref: workspace_path,
          provider_key: provider_class.provider_key,
          display_name: name.presence || provider_class.display_name,
          capabilities: provider_class.capabilities(repository, config),
          primary: !chat_session.runtime_sessions.active.exists?,
          state: "starting"
        )

        current = RuntimeSessions::Operation.reconcile_expired!(runtime_session)
        if current&.fetch("state", nil) == "active"
          return Mcp::Tools.success(runtime_session_payload(runtime_session.reload))
        end

        runtime_session.update!(state: "starting", last_error: nil)
        operation = RuntimeSessions::Operation.new(session: runtime_session, kind: :startup)
        result = operation.call do
          provider_class.new.start_session(workspace_path, config.merge(runtime_session: runtime_session))
        end
        return Mcp::Tools.invalid("failed to start runtime session: #{result.error.message}") if result.error && !result.timed_out?
        return Mcp::Tools.invalid(result.error) if result.timed_out?

        Mcp::Tools.success(runtime_session_payload(runtime_session.reload))
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
