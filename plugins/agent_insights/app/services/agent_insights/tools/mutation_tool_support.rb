module AgentInsights
  module Tools
    module MutationToolSupport
      include Mcp::Tools::BulkPendingActionToolSupport

      private

      def mutation_context(server_context)
        context = McpToolContext.from_server_context(server_context)
        chat_session = server_context[:chat_session]
        actor = context.run || context.user
        scope = if context.run?
          Repository.where(id: context.repository || context.run&.job&.repository)
        elsif context.user.admin?
          Repository.all
        else
          Repository.where(id: context.allowed_repository_ids)
        end
        [ context, chat_session, actor, scope ]
      end

      def execute_or_confirm(mutation:, ids:, chat_session:, server_context:, action:, payload:, message:)
        validation = mutation.validate
        return Mcp::Tools.invalid(validation.message) unless validation.ok?

        if ids.size == 1
          result = mutation.apply!
          return mutation_response(result)
        end

        return Mcp::Tools.invalid("bulk insight mutations require a chat session") unless chat_session

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: [ {
            action: action,
            payload: payload.merge("proposal_types" => validation.suggestions.to_h { |item| [ item.id.to_s, item.effective_proposal_type ] }),
            requested_by: "agent"
          } ]
        )
        bulk_action_response(
          group: group,
          message: message,
          extra: { insight_ids: ids, proposal_types: validation.suggestions.to_h { |item| [ item.id, item.effective_proposal_type ] }, intended_transition: action }
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end

      def mutation_response(result)
        Mcp::Tools.success(
          message: result.message,
          insight_ids: result.suggestions.map(&:id),
          states: result.suggestions.to_h { |item| [ item.id, item.state ] },
          proposal_types: result.suggestions.to_h { |item| [ item.id, item.effective_proposal_type ] },
          job_ids: Array(result.jobs).map(&:id),
          memory_ids: Array(result.memories).map(&:id)
        )
      end
    end
  end
end
