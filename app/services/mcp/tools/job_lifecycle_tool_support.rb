module Mcp::Tools
  module JobLifecycleToolSupport
    private

    def find_repository_job(chat_session, job_id)
      normalized_id = Integer(job_id, exception: false)
      return [ nil, Mcp::Tools.invalid("job_id is required") ] unless normalized_id

      scope = chat_session.user.admin? ? Job.all : chat_session.user.jobs
      job = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("job not found: #{normalized_id}") ] unless job

      [ job, nil ]
    end

    def find_repository_epic(chat_session, epic_id)
      normalized_id = Integer(epic_id, exception: false)
      return [ nil, Mcp::Tools.invalid("epic_id is required") ] unless normalized_id

      scope = chat_session.user.admin? ? Epic.all : Epic.where(repository: chat_session.user.repositories.active)
      epic = scope.find_by(id: normalized_id)
      return [ nil, Mcp::Tools.invalid("epic not found: #{normalized_id}") ] unless epic

      [ epic, nil ]
    end

    def invalid_record(error)
      Mcp::Tools.invalid(error.record.errors.full_messages.to_sentence)
    end
  end
end
