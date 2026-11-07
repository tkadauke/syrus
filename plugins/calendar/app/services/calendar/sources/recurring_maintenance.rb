module Calendar
  module Sources
    class RecurringMaintenance
      def self.calendar_events(user:, starts_at:, ends_at:)
        return [] unless user.admin?

        definitions.map do |key, definition|
          schedule = definition.fetch("schedule")
          observation = execution_observation(definition["class"], starts_at, ends_at)
          Event.new(source_id: "calendar:solid_queue", id: "recurring-#{key}", kind: "recurring_maintenance",
            title: definition["class"] || key.humanize, starts_at:, ends_at:, cadence: { label: schedule, band: high_frequency?(schedule) },
            destination_path: "/admin/queues", state: observation[:state], actual_started_at: observation[:started_at],
            actual_finished_at: observation[:finished_at],
            metadata: { key:, queue: definition["queue"], schedule:, duration_seconds: observation[:duration_seconds] }.compact)
        end
      end

      def self.definitions
        all = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
        all.fetch(Rails.env, all.fetch("default", {}))
      end

      def self.high_frequency?(schedule)
        schedule.match?(/(?:second|minute|30 seconds|5 minutes|10 minutes|15 minutes|30 minutes)/i)
      end

      def self.execution_observation(class_name, starts_at, ends_at)
        return { state: "planned" } if class_name.blank?
        job = SolidQueue::Job.where(class_name:, created_at: starts_at...ends_at).order(created_at: :desc).first
        return { state: "planned" } unless job
        { state: job.finished_at? ? "healthy" : "running", started_at: job.created_at, finished_at: job.finished_at,
          duration_seconds: job.finished_at && (job.finished_at - job.created_at).round(3) }
      rescue ActiveRecord::StatementInvalid
        { state: "unknown" }
      end
    end
  end
end
