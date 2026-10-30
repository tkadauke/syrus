require "mcp"

module Coworkers::McpTools
  class ListCoworkersTool < MCP::Tool
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 50
    MAX_QUERY_LENGTH = 200

    tool_name "list_coworkers"
    description "List only the signed-in owner's persistent coworkers, ordered by name and id. Supports optional state and bounded text filters."
    input_schema(
      properties: {
        state: { type: "string", enum: Coworkers::Coworker::STATES },
        query: { type: "string", maxLength: MAX_QUERY_LENGTH, description: "Match name, handle, or role summary (max 200 characters)." },
        limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "Maximum results (default 20, max 50)." }
      }
    )

    class << self
      def call(server_context:, state: nil, query: nil, limit: nil)
        owner = server_context.fetch(:chat_session).user
        relation = Coworkers::OwnerResolver.new(owner: owner).scope.includes(avatar_attachment: :blob, coworker_chats: :chat_session)
        return Mcp::Tools.invalid("state must be one of #{Coworkers::Coworker::STATES.join(', ')}") if state.present? && !Coworkers::Coworker::STATES.include?(state.to_s)

        relation = relation.where(state: state) if state.present?
        if query.present?
          normalized_query = query.to_s.strip
          return Mcp::Tools.invalid("query must be at most #{MAX_QUERY_LENGTH} characters") if normalized_query.length > MAX_QUERY_LENGTH

          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query.downcase)}%"
          relation = relation.where("LOWER(name) LIKE :query OR LOWER(handle) LIKE :query OR LOWER(role_summary) LIKE :query", query: pattern)
        end
        bounded_limit = limit.nil? ? DEFAULT_LIMIT : limit.to_i.clamp(1, MAX_LIMIT)
        coworkers = relation.order(Arel.sql("LOWER(name) ASC"), :id).limit(bounded_limit)
        Mcp::Tools.success(coworkers: coworkers.map { |coworker| Coworkers::McpPresenter.new(coworker).summary }, limit: bounded_limit)
      rescue StandardError => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
