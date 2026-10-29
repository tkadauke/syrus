require "mcp"

module Coworkers::McpTools
  class ProposeCoworkerTool < MCP::Tool
    extend Mcp::Tools::ProposalToolSupport
    extend Mcp::Tools::PendingActionToolSupport

    tool_name "propose_coworker"
    description "Propose a persistent coworker. Validates the complete configuration and remote now; nothing is created until the owner confirms."
    input_schema(
      properties: {
        name: { type: "string" }, handle: { type: "string" }, workspace_repo: { type: "string" },
        about: { type: "string" }, color_key: { type: "string" }, avatar_key: { type: "string" },
        chat_provider: { type: "string" }, chat_model: { type: "string" }, chat_effort: { type: "string" },
        grants: { type: "array", items: { type: "string" } },
        test_push: { type: "boolean", description: "Test push access during preflight (defaults to true)." }
      },
      required: %w[name handle workspace_repo grants]
    )

    class << self
      def call(name:, handle:, workspace_repo:, grants:, server_context:, about: nil, color_key: nil,
               avatar_key: nil, chat_provider: nil, chat_model: nil, chat_effort: nil, test_push: true)
        chat = server_context.fetch(:chat_session)
        fields = { "name" => name.to_s.strip, "handle" => HandleRegistry.normalize(handle),
          "workspace_repo" => workspace_repo.to_s.strip, "about" => about.to_s.strip.presence,
          "color_key" => color_key, "avatar_key" => avatar_key, "chat_provider" => chat_provider,
          "chat_model" => chat_model, "chat_effort" => chat_effort,
          "grants" => Array(grants).map(&:to_s).uniq }.compact
        preflight_fields = fields.except("about")
        Coworkers::CreatePreflight.new(owner: chat.user, **preflight_fields.symbolize_keys, test_push: test_push != false).call
        pending_action = create_pending_action_for_current_message!(
          server_context, chat, action: "create_coworker", payload: fields, requested_by: "agent"
        )
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id, pending_action_id: pending_action.id,
          state: pending_action.state, message: "Create coworker @#{fields['handle']}?",
          coworker: fields
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      rescue StandardError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
