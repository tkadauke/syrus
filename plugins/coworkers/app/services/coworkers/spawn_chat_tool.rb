require "mcp"

module Coworkers
  class SpawnChatTool < MCP::Tool
    DEFAULT_PER_RUN_CAP = 3
    DEFAULT_PER_DAY_CAP = 10

    tool_name "spawn_coworker_chat"
    description "Create a side chat for the current coworker with an initial owner message. The grant approval and spawn caps always apply."
    input_schema(
      properties: {
        prompt: { type: "string", description: "The initial message in the new side chat." },
        handle: { type: "string", description: "Optional current coworker handle; another handle is refused." },
        title: { type: "string", description: "Optional side-chat title." }
      },
      required: %w[prompt]
    )

    class << self
      def call(prompt:, server_context:, handle: nil, title: nil)
        context = McpToolContext.from_server_context(server_context)
        coworker = context.agent_actor
        return Mcp::Tools.invalid("spawn_coworker_chat is only available to a coworker") unless coworker.is_a?(Coworkers::Coworker)
        return Mcp::Tools.invalid("coworker.spawn_chat grant is required") unless context.granted_capabilities.include?("coworker.spawn_chat")

        requested_handle = HandleRegistry.normalize(handle.to_s.delete_prefix("@")) if handle.present?
        return Mcp::Tools.invalid("a coworker can only spawn a side chat of itself") if requested_handle && requested_handle != coworker.handle
        return Mcp::Tools.invalid("prompt is required") if prompt.to_s.strip.blank?

        limiter = Coworkers::SpawnChatLimiter.new(coworker:, server_context:)
        return Mcp::Tools.invalid(limiter.refusal) unless limiter.allowed?

        pending = Mcp::Tools::AuthorizationSupport.pending_coworker_plugin_approval(
          tool_name, "coworker.spawn_chat", server_context, { prompt: prompt, handle: coworker.handle, title: title }, always_pending: true
        )
        return pending if pending

        result = Coworkers::SpawnChat.call(coworker:, prompt:, title:, server_context:)
        Mcp::Tools.success(chat_id: result.id, chat_path: "/chats/#{result.id}", handle: coworker.handle)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
