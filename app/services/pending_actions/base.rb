module PendingActions
  class Base
    def self.action_key(key = nil)
      if key
        @action_key = key.to_s
        PendingActions.register(self)
      elsif instance_variable_defined?(:@action_key)
        @action_key
      else
        raise NotImplementedError, "#{name} must define an action_key"
      end
    end

    def initialize(action)
      @action = action
    end

    def execute
      raise NotImplementedError
    end

    def validate_payload(errors)
      # no-op by default
    end

    def action_detail
      "id: #{@action.id}"
    end

    def repair_action?
      false
    end

    def repair_snapshot_targets
      []
    end

    private

    attr_reader :action

    def payload
      @action.payload.to_h
    end

    def reason
      @action.reason.to_s.strip
    end

    def user
      @action.user
    end

    def chat_session
      @action.chat_session
    end

    def repository
      @action.repository
    end

    def action_job
      user.jobs.find(payload.fetch("job_id"))
    end

    def repair_action_job
      scope = user.admin? ? Job.all : user.jobs
      scope.find(payload.fetch("job_id"))
    end

    def repair_action_job_or_nil
      scope = user.admin? ? Job.all : user.jobs
      scope.find_by(id: payload["job_id"])
    end

    def action_user_job
      user.jobs.find(payload.fetch("job_id"))
    end

    def action_scheduled_task
      ScheduledTask.alive.where(user: user).find(payload.fetch("scheduled_task_id"))
    end

    def action_user_repository
      user.repositories.active.find(payload.fetch("repository_id"))
    end

    def action_user_document
      Document.where(
        attachable_type: "Repository",
        attachable_id: user.repositories.active.select(:id)
      ).find(payload.fetch("document_id"))
    end

    def document_filename(title)
      basename = title.to_s.parameterize.presence || "document"
      "#{basename.first(80)}.md"
    end
  end
end
