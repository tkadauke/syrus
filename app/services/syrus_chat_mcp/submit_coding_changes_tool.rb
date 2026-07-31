require "mcp"

module SyrusChatMcp
  class SubmitCodingChangesTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "submit_coding_changes"

    description <<~DESC
      Create a Syrus Job from committed branch changes and dispatch the CodingHandoff
      workflow (graders → summarize → PR open). Use this after committing the
      implementation. The current branch is captured to an immutable handoff branch
      after the operator confirms the pending action; you do not need to push a
      standalone chat branch first.
      Only available when the coding_mode feature is enabled.
    DESC

    input_schema(
      properties: {
        repository_id: {
          type: "integer",
          description: "Repository ID to create the Job in. Defaults to the chat session's attached repository."
        },
        branch: {
          type: "string",
          description: "The current git branch containing the committed implementation. Defaults to the active coding checkout branch."
        },
        title: {
          type: "string",
          description: "A short, one-line title for this job (e.g. \"Add dark mode toggle\"). Keep it under 80 characters."
        },
        description: {
          type: "string",
          description: "A brief, one-paragraph summary of what was implemented — 2 to 4 sentences maximum. Do NOT include git logs, file listings, command output, or exhaustive change lists. The operator reads this in a small confirmation card, so brevity is essential."
        }
      },
      required: %w[title description]
    )

    class << self
      def call(title:, description:, branch: nil, repository_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)

        return SyrusChatMcp.invalid("Coding Mode is not enabled") unless Feature.coding_mode_enabled?

        repository = resolve_repository(chat_session, repository_id)
        return SyrusChatMcp.invalid("repository not found or not accessible") unless repository

        branch = branch.to_s.strip.presence || current_checkout_branch(chat_session, repository).to_s.strip
        return SyrusChatMcp.invalid("branch is required") if branch.blank?

        title = title.to_s.strip
        return SyrusChatMcp.invalid("title is required") if title.blank?

        description = description.to_s.strip
        return SyrusChatMcp.invalid("description is required") if description.blank?

        payload = {
          "repository_id" => repository.id,
          "branch" => branch,
          "title" => title,
          "description" => description
        }

        pending_action = chat_session.pending_actions.create!(
          action: "submit_coding_changes",
          state: "pending",
          payload: payload,
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Submit coding changes is pending operator confirmation. " \
                   "Once confirmed, a Job will be created and the CodingHandoff workflow " \
                   "(graders, summarize, PR open) will be dispatched for branch '#{branch}'."
        )
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

      def current_checkout_branch(chat_session, repository)
        ChatWorkspace.coding_checkout_snapshot(chat_session, repository)[:current_branch].presence
      rescue StandardError
        nil
      end
    end
  end
end
