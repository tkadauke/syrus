require "mcp"

module Mcp::Tools
  class SpawnChatsTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    MAX_CHATS = 10

    tool_name "spawn_chats"

    description <<~DESC
      Request creation of up to #{MAX_CHATS} new chat threads. Each chat starts
      with the supplied user prompt. Nothing is created until the operator
      confirms the grouped pending action.
    DESC

    input_schema(
      properties: {
        chats: {
          type: "array",
          minItems: 1,
          maxItems: MAX_CHATS,
          items: {
            type: "object",
            properties: {
              prompt: { type: "string" },
              provider: { type: "string" },
              title: { type: "string" },
              repository: { type: "string", description: "Accessible repository slug (owner/name)." }
            },
            required: [ "prompt" ]
          }
        },
        reason: { type: "string", description: "Why these chats should be created." }
      },
      required: [ "chats" ]
    )

    class << self
      def call(chats:, reason: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        entries = Array(chats)
        return Mcp::Tools.invalid("chats must not be empty") if entries.empty?
        return Mcp::Tools.invalid("chats cannot contain more than #{MAX_CHATS} entries") if entries.size > MAX_CHATS

        payloads = entries.each_with_index.map do |entry, index|
          normalized_entry(entry, index: index, chat_session: chat_session, batch_size: entries.size)
        end
        error = payloads.find { |payload| payload.is_a?(String) }
        return Mcp::Tools.invalid(error) if error

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: payloads.map { |payload| { action: "spawn_chat", payload: payload, requested_by: "agent" } },
          reason: reason
        )
        bulk_action_response(group: group, message: "Spawn #{entries.size} #{'chat'.pluralize(entries.size)}?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def normalized_entry(entry, index:, chat_session:, batch_size:)
        return "chat #{index + 1} must be an object" unless entry.respond_to?(:to_h)

        entry = entry.to_h.stringify_keys
        prompt = entry["prompt"].to_s.strip
        return "chat #{index + 1} prompt must not be blank" if prompt.blank?

        provider = entry["provider"].to_s.strip.presence
        return "chat #{index + 1} provider is unknown" if provider && !User.chat_providers.include?(provider)
        if provider && !chat_session.user.chat_provider_configured?(provider)
          return "chat #{index + 1} provider is not configured"
        end

        repository = resolve_repository(entry["repository"], chat_session)
        return "chat #{index + 1} repository is not accessible" if repository == :inaccessible

        {
          "prompt" => prompt,
          "provider" => provider,
          "title" => entry["title"].to_s.strip.presence,
          "repository_id" => repository&.id,
          "batch_size" => batch_size
        }.compact
      end

      def resolve_repository(slug, chat_session)
        return chat_session.repository if slug.to_s.strip.blank?

        owner, name = slug.to_s.strip.split("/", 2)
        return :inaccessible if owner.blank? || name.blank?

        Repository.accessible_to(chat_session.user).active
          .find_by("LOWER(owner) = ? AND LOWER(name) = ?", owner.downcase, name.downcase) || :inaccessible
      end
    end
  end
end
