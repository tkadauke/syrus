module Mcp::Tools
  module ChatPinning
    include AuthorizationSupport

    InvalidInput = Class.new(StandardError)

    private

    def pin_chat!(server_context:, chat_session_id:, pinned:)
      Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
        target = resolve_chat_session(chat_session_id)
        target.update!(pinned: pinned)

        Mcp::Tools.success(
          session_id: target.id,
          title: target.title.presence || ChatSession.fallback_title_for(target.repository) || "Untitled chat",
          pinned: target.pinned?,
          message: target.pinned? ? "Chat pinned." : "Chat unpinned."
        )
      end
    rescue InvalidInput => e
      Mcp::Tools.invalid(e.message)
    rescue Mcp::Tools::AuthorizationSupport::AuthorizationError
      Mcp::Tools.not_authorized
    end

    def resolve_chat_session(chat_session_id)
      id = normalize_chat_session_id(chat_session_id)
      id ||= chat_session.id

      current_user
        .accessible_chat_sessions
        .visible
        .active
        .find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationSupport::AuthorizationError, "chat session not found or not accessible"
    end

    def normalize_chat_session_id(value)
      return nil if value.nil? || value.to_s.strip.empty?

      id = Integer(value, exception: false)
      raise InvalidInput, "chat_session_id must be a positive integer" unless id&.positive?

      id
    end
  end
end
