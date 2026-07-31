module Mcp::Tools
  module PendingActionToolSupport
    private

    def create_pending_action!(server_context, chat_session, action:, payload:, message:)
      pending_action = create_pending_action_for_current_message!(
        server_context,
        chat_session,
        action: action,
        payload: payload,
        requested_by: "agent"
      )

      Mcp::Tools.success(
        pending_confirmation_id: pending_action.id,
        pending_action_id: pending_action.id,
        state: pending_action.state,
        message: message
      )
    end

    def user_job(chat_session, job_id)
      normalized_id = Integer(job_id, exception: false)
      return [ nil, Mcp::Tools.invalid("job_id is required") ] unless normalized_id

      scope = chat_session.user.admin? ? Job.all : chat_session.user.jobs
      job = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("job not found: #{normalized_id}") ] unless job

      [ job, nil ]
    end

    def user_repository(chat_session, repository_id)
      normalized_id = Integer(repository_id, exception: false)
      return [ nil, Mcp::Tools.invalid("repository_id is required") ] unless normalized_id

      scope = chat_session.user.admin? ? Repository.active : chat_session.user.repositories.active
      repository = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("repository not found: #{normalized_id}") ] unless repository

      [ repository, nil ]
    end

    def user_document(chat_session, document_id)
      normalized_id = Integer(document_id, exception: false)
      return [ nil, Mcp::Tools.invalid("document_id is required") ] unless normalized_id

      document = Document.where(
        attachable_type: "Repository",
        attachable_id: chat_session.user.repositories.active.select(:id)
      ).find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("document not found: #{normalized_id}") ] unless document

      [ document, nil ]
    end

    def invalid_record(error)
      Mcp::Tools.invalid(error.record.errors.full_messages.to_sentence)
    end
  end
end
