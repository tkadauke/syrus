require "mcp"

module SyrusChatMcp
  class ResetWorkspaceTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "reset_workspace"

    description <<~DESC
      Report or reset the Coding Mode repository checkout for this chat.
      By default this is a status-only safe no-op. When confirm_discard is true,
      the checkout is reset to the repository default branch tip, uncommitted
      changes and local-only commits are discarded, Coding Mode checkout state is
      refreshed, and ChatWorkspacePrepareJob is queued for the next turn.
      Only available when the coding_mode feature is enabled.
    DESC

    input_schema(
      properties: {
        repository_id: {
          type: "integer",
          description: "Repository ID to reset. Defaults to the chat session's attached repository."
        },
        confirm_discard: {
          type: "boolean",
          description: "Must be true to discard local uncommitted work or commits ahead of the default branch."
        }
      }
    )

    class << self
      def call(confirm_discard: false, repository_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)

        return SyrusChatMcp.invalid("Coding Mode is not enabled") unless Feature.coding_mode_enabled?

        repository = resolve_repository(chat_session, repository_id)
        return SyrusChatMcp.invalid("repository not found or not accessible") unless repository

        if ActiveModel::Type::Boolean.new.cast(confirm_discard)
          reset = ChatWorkspace.reset_coding_workspace!(chat_session, repository, confirm_discard: true)
          return SyrusChatMcp.success(
            reset.merge(
              message: "Coding workspace reset to #{repository.default_branch}; preparation was queued again."
            )
          )
        end

        status = ChatWorkspace.coding_reset_status(chat_session, repository)
        if status[:destructive_reset_required]
          return refused(status)
        end

        SyrusChatMcp.success(
          reset: false,
          status: status,
          message: "Workspace status only; no reset was performed."
        )
      rescue ChatWorkspace::ResetRefused => e
        refused(e.status, message: e.message)
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def resolve_repository(chat_session, repository_id)
        if repository_id.present?
          chat_session.user.repositories.active.find_by(id: repository_id)
        else
          chat_session.repository
        end
      end

      def refused(status, message: "reset_workspace would discard local work; call it again with confirm_discard: true to reset.")
        MCP::Tool::Response.new(
          [
            {
              type: "text",
              text: JSON.generate(error: "confirmation_required", message: message, status: status)
            }
          ],
          error: true
        )
      end
    end
  end
end
