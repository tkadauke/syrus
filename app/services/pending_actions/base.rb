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

    # Marks the action as an operator repair against a single Job, with the
    # default before/after snapshot target of that Job. Actions repairing a
    # different kind of record (e.g. an Epic) should override
    # `repair_action?`/`repair_snapshot_targets` directly instead.
    def self.repairs_job!
      define_method(:repair_action?) { true }
      define_method(:repair_snapshot_targets) { [ repair_action_job_or_nil ] }
    end

    def initialize(action)
      @action = action
    end

    def execute
      require_admin!
      perform
    end

    def perform
      raise NotImplementedError
    end

    def validate_payload(errors)
      # no-op by default
    end

    def action_detail
      "id: #{@action.id}"
    end

    def execution_label
      "Running #{self.class.action_key.to_s.humanize(capitalize: false)}..."
    end

    def repair_action?
      false
    end

    def repair_snapshot_targets
      []
    end

    private

    attr_reader :action

    def require_admin!
      raise ArgumentError, "Admin access required." unless user.admin?
    end

    def audit!(message, run:)
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] #{message}; reason=#{reason}",
        kind: "system"
      )
    end

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

    def progress!(message)
      @action.update_confirmation_progress!("running", message)
    end
  end
end
