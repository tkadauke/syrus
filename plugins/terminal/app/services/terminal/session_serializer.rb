module Terminal
  class SessionSerializer
    def self.render(session)
      new(session).render
    end

    def initialize(session)
      @session = session
    end

    def render
      {
        id: @session.id,
        name: @session.name,
        working_directory: @session.working_directory,
        relay_address: @session.relay_address,
        started_at: iso8601(@session.started_at),
        finished_at: iso8601(@session.finished_at),
        outcome: @session.outcome,
        workflow_id: @session.workflow_id,
        chat_session_id: @session.chat_session_id,
        worker_hostname: @session.worker_hostname,
        worker_storage_key: @session.worker_storage_key,
        queue_name: @session.queue_name,
        workspace_kind: @session.workspace_kind
      }
    end

    private

    def iso8601(value)
      value&.iso8601
    end
  end
end
