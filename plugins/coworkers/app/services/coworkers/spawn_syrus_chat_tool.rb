require "mcp"

module Coworkers
  class SpawnSyrusChatTool < MCP::Tool
    DEFAULT_PER_RUN_CAP = 3
    DEFAULT_PER_DAY_CAP = 10

    tool_name "spawn_syrus_chat"
    def self.coworker_capability = "syrus.spawn_chat"
    def self.coworker_approval_effect? = true
    def self.coworker_descriptor
      Permissions::CoworkerActions.descriptor(tool_name:, family: coworker_capability,
        effects: %i[internal_write communication persistent_autonomy], risk: :medium, default: :ask)
    end

    description <<~DESC
      Ask the owner to create a regular Syrus engineering/planner chat in an
      accessible repository and send it an initial message. This is not a side
      chat of the coworker. After approval, continue the resulting bridge with
      reply_in_chat_thread and read replies delivered to this coworker chat.
    DESC
    input_schema(
      properties: {
        repository_id: { type: "integer", description: "Repository to attach to the planner chat." },
        prompt: { type: "string", description: "Initial message for the Syrus planner." },
        title: { type: "string", description: "Optional planner-chat title." }
      },
      required: %w[repository_id prompt]
    )

    class << self
      def call(repository_id:, prompt:, server_context:, title: nil)
        context = McpToolContext.from_server_context(server_context)
        coworker = context.agent_actor
        return Mcp::Tools.invalid("spawn_syrus_chat is only available to a coworker") unless coworker.is_a?(Coworkers::Coworker)
        return Mcp::Tools.invalid("prompt is required") if prompt.to_s.strip.blank?

        repository = Mcp::Tools::CoworkerRepositoryAccess.resolve_for_capability(
          server_context:, capability: "syrus.spawn_chat", repository_id:
        )
        return repository if repository.is_a?(MCP::Tool::Response)

        coworker.with_lock do
          limiter = Coworkers::SpawnChatLimiter.new(
            coworker:, server_context:, capability: "syrus.spawn_chat", tool_name:, label: "Syrus-chat"
          )
          next Mcp::Tools.invalid(limiter.refusal) unless limiter.allowed?

          arguments = { repository_id: repository.id, prompt:, title: }
          pending = Mcp::Tools::AuthorizationSupport.pending_coworker_plugin_approval(
            tool_name, "syrus.spawn_chat", server_context, arguments, always_pending: true
          )
          next pending if pending

          result = Coworkers::SpawnSyrusChat.call(coworker:, repository:, prompt:, title:, server_context:)
          Mcp::Tools.success(
            chat_id: result.fetch(:chat).id,
            chat_path: "/chats/#{result.fetch(:chat).id}",
            thread_id: result.fetch(:thread).id,
            repository: repository.slug,
            opened_by: "@#{coworker.handle}"
          )
        end
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
