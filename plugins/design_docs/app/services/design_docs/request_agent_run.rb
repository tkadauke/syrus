module DesignDocs
  class RequestAgentRun
    Result = Data.define(:run, :enqueued)

    def self.call(...)
      new(...).call
    end

    def initialize(comment:, user:)
      @comment = comment
      @user = user
      @thread = comment.thread
      @design_doc = thread.design_doc
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).suggest?
      enqueued = false
      run = nil

      thread.with_lock do
        run = existing_trigger_run || active_thread_run
        unless run
          run = DesignDocs::DesignDocAgentRun.create!(
            design_doc: design_doc,
            thread: thread,
            triggering_comment: comment,
            requested_by_user: user,
            base_version: design_doc.current_version,
            agent_provider: agent_provider,
            status: "queued",
            context_snapshot: DesignDocs::AgentRunContext.new(
              design_doc: design_doc,
              thread: thread,
              triggering_comment: comment,
              requested_by_user: user
            ).to_h
          )
          enqueued = true
        end
      end

      if enqueued
        DesignDocs::AgentRunJob.perform_later(run.id)
        DesignDocs::CommentBroadcaster.call(design_doc: design_doc, changed: [ "agent_runs" ])
      end

      Result.new(run: run, enqueued: enqueued)
    end

    private

    attr_reader :comment, :user, :thread, :design_doc

    def existing_trigger_run
      @existing_trigger_run ||= DesignDocs::DesignDocAgentRun.find_by(triggering_comment: comment)
    end

    def active_thread_run
      @active_thread_run ||= thread.agent_runs.active.latest_first.first
    end

    def agent_provider
      design_doc.repositories.first&.effective_agent_provider(user: user).presence || user.agent_provider
    end
  end
end
