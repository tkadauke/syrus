require "mcp"

module Mcp::Tools
  class ListChatsTool < MCP::Tool
    tool_name "list_chats"

    description "List the current operator's recent Syrus chat sessions, optionally filtering by chat mode or attached Jobs."

    input_schema(
      properties: {
        mode: { type: "string", enum: ChatSession::MODES, description: "Optional chat mode filter: planning, coding, or local. Planning includes chats with no stored mode." },
        job_id: { type: "integer", description: "Optional attached Syrus Job id filter." },
        has_attached_jobs: { type: "boolean", description: "Optional filter for chats that do or do not have attached Jobs." },
        page: { type: "integer", description: "1-based page number. Defaults to 1." },
        per_page: { type: "integer", description: "Sessions per page. Defaults to 20, capped at 100." }
      }
    )

    class << self
      include ChatDiscoveryPayload

      def call(server_context:, page: 1, per_page: 20, mode: nil, job_id: nil, has_attached_jobs: nil)
        chat_session = server_context.fetch(:chat_session)
        page = normalize_page(page)
        per_page = normalize_per_page(per_page)
        scope = ChatSession
          .where(user: chat_session.user)
          .visible
          .active
          .order(updated_at: :desc)
        scope = apply_mode_filter(scope, mode)
        return scope if scope.is_a?(MCP::Tool::Response)
        scope = apply_attached_job_filter(scope, job_id)
        return scope if scope.is_a?(MCP::Tool::Response)
        scope = apply_has_attached_jobs_filter(scope, has_attached_jobs)
        return scope if scope.is_a?(MCP::Tool::Response)

        total_count = scope.count
        sessions = scope
          .preload(:attached_repositories, attached_jobs: :repository)
          .offset((page - 1) * per_page)
          .limit(per_page)
          .to_a
        message_counts = message_counts_for(sessions)

        Mcp::Tools.success(
          chats: sessions.map { |session| payload_for(session, message_count: message_counts.fetch(session.id, 0)) },
          pagination: {
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil,
            has_next_page: page * per_page < total_count
          }
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def normalize_per_page(value)
        value.to_i.clamp(1, 100)
      end

      def apply_mode_filter(scope, mode)
        mode = mode.to_s.strip.presence
        return scope unless mode
        return Mcp::Tools.invalid("mode must be one of: #{ChatSession::MODES.join(', ')}") unless ChatSession::MODES.include?(mode)

        return scope.where(mode: [ nil, "planning" ]) if mode == "planning"

        scope.where(mode: mode)
      end

      def apply_attached_job_filter(scope, job_id)
        return scope if job_id.nil? || job_id.to_s.strip.empty?

        id = Integer(job_id, exception: false)
        return Mcp::Tools.invalid("job_id must be a positive integer") unless id&.positive?

        scope.joins(:job_attachments).where(chat_attachments: { attachable_id: id })
      end

      def apply_has_attached_jobs_filter(scope, value)
        boolean = normalize_boolean(value, "has_attached_jobs")
        return boolean if boolean.is_a?(MCP::Tool::Response)
        return scope if boolean.nil?

        boolean ? scope.joins(:job_attachments).distinct : scope.where.missing(:job_attachments)
      end

      def normalize_boolean(value, name)
        return nil if value.nil?
        return value if value == true || value == false

        normalized = value.to_s.strip.downcase
        return true if normalized == "true"
        return false if normalized == "false"

        Mcp::Tools.invalid("#{name} must be true or false")
      end

      def message_counts_for(sessions)
        ids = sessions.map(&:id)
        return {} if ids.empty?

        ChatMessage.where(chat_session_id: ids).group(:chat_session_id).count
      end

      def payload_for(session, message_count:)
        repository = session.repository

        {
          id: session.id,
          title: session.title.presence || ChatSession.fallback_title_for(repository),
          message_count: message_count,
          updated_at: session.updated_at.iso8601
        }.merge(chat_discovery_payload(session))
      end
    end
  end
end
