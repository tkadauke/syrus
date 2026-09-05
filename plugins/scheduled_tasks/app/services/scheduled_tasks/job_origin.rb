module ScheduledTasks
  # The origin for Jobs a ScheduledTask fired.
  #
  # Lives in core only until scheduled_tasks becomes a plugin -- it is written
  # against the plugin contract so the move is a file relocation plus dropping
  # it from Job::Origin::BUILT_IN_PROVIDERS, with no change to any caller.
  class JobOrigin
    include Syrus::Plugin::JobOrigin

    def self.origin_key = "scheduled_tasks"

    def self.label(origin_id:, repository: nil)
      task(origin_id)&.name.presence || "task ##{origin_id}"
    end

    def self.url(origin_id:, repository: nil)
      return nil if task(origin_id).nil?

      "/scheduled_tasks/#{origin_id}"
    end

    # The prompt a scheduled fire runs. Job#synthetic_issue used to reach into
    # ScheduledTask for exactly this.
    def self.synthetic_issue(origin_id:, repository: nil)
      found = task(origin_id)
      return nil if found.nil?

      { title: "Scheduled task: #{found.name}", body: found.prompt.to_s }
    end

    def self.auto_approve_mode(origin_id:, repository: nil)
      task(origin_id)&.auto_approve_mode
    end

    def self.task(origin_id)
      return nil if origin_id.blank?

      ScheduledTasks::Task.find_by(id: origin_id)
    end
    private_class_method :task
  end
end
