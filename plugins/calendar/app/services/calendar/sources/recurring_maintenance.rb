module Calendar
  module Sources
    class RecurringMaintenance
      BAND_THRESHOLD = 30.minutes
      MAX_OBSERVATIONS_PER_CLASS = 100

      def self.calendar_events(user:, starts_at:, ends_at:)
        return [] unless user.admin?

        configured = definitions
        observations_by_class = execution_observations_by_class(configured.values.filter_map { |definition| definition["class"] }, starts_at, ends_at)
        configured.flat_map do |key, definition|
          schedule = definition.fetch("schedule")
          parsed = Fugit.parse(schedule)
          raise ArgumentError, "invalid recurring schedule #{schedule.inspect}" unless parsed.respond_to?(:next_time)
          interval = cadence_interval(parsed, starts_at)
          observations = observations_by_class.fetch(definition["class"], [])
          if interval <= BAND_THRESHOLD
            [ build_event(key:, definition:, schedule:, starts_at:, ends_at:, band: true, observation: band_observation(observations)) ]
          else
            occurrences(parsed, starts_at, ends_at).map do |planned_at|
              observation = closest_observation(observations, planned_at, interval)
              build_event(key:, definition:, schedule:, starts_at: planned_at, band: false, observation:)
            end
          end
        end
      end

      def self.definitions
        all = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
        all.fetch(Rails.env, all.fetch("default", {}))
      end

      def self.cadence_interval(schedule, starts_at)
        first = schedule.next_time(starts_at - 1.second).utc
        second = schedule.next_time(first).utc
        second - first
      end

      def self.occurrences(schedule, starts_at, ends_at)
        planned = []
        cursor = starts_at - 1.second
        loop do
          occurrence = schedule.next_time(cursor).utc
          break if occurrence >= ends_at
          planned << occurrence if occurrence >= starts_at
          cursor = occurrence
        end
        planned
      end

      def self.execution_observations_by_class(class_names, starts_at, ends_at)
        ranked_jobs = SolidQueue::Job
          .where(class_name: class_names.uniq, created_at: starts_at...ends_at)
          .select("solid_queue_jobs.*, ROW_NUMBER() OVER (PARTITION BY class_name ORDER BY created_at DESC) AS calendar_row_number")
        jobs = SolidQueue::Job.from("(#{ranked_jobs.to_sql}) solid_queue_jobs")
          .where("calendar_row_number <= ?", MAX_OBSERVATIONS_PER_CLASS).order(:created_at).to_a
        failed_ids = SolidQueue::FailedExecution.where(job_id: jobs.map(&:id)).pluck(:job_id).to_set
        jobs.group_by(&:class_name).transform_values do |class_jobs|
          class_jobs.map do |job|
            state = if failed_ids.include?(job.id)
              "attention"
            elsif job.finished_at?
              "healthy"
            else
              "running"
            end
            { state:, started_at: job.created_at, finished_at: job.finished_at,
              duration_seconds: job.finished_at && (job.finished_at - job.created_at).round(3) }
          end
        end
      rescue ActiveRecord::StatementInvalid
        {}
      end

      def self.closest_observation(observations, planned_at, interval)
        observations.min_by { |item| (item[:started_at] - planned_at).abs }
          &.then { |item| (item[:started_at] - planned_at).abs <= interval / 2 ? item : nil }
      end

      def self.band_observation(observations)
        observations.reverse.find { |item| item[:state] == "attention" } ||
          observations.reverse.find { |item| item[:state] == "running" } || observations.last
      end

      def self.build_event(key:, definition:, schedule:, starts_at:, band:, observation:, ends_at: nil)
        observation ||= { state: "planned" }
        estimate = observation[:duration_seconds] || 1.minute.to_i
        occurrence_id = band ? "band" : starts_at.utc.strftime("%Y%m%dT%H%M%SZ")
        Event.new(source_id: "calendar:solid_queue", id: "recurring-#{key}-#{occurrence_id}", kind: "recurring_maintenance",
          title: definition["class"] || key.humanize, starts_at:, ends_at:,
          cadence: { label: schedule, band: }, destination_path: "/admin/queues", state: observation[:state],
          actual_started_at: observation[:started_at], actual_finished_at: observation[:finished_at],
          estimated_duration_seconds: estimate,
          duration_estimate_provenance: "source",
          metadata: { key:, queue: definition["queue"], schedule:, duration_seconds: observation[:duration_seconds] }.compact)
      end
    end
  end
end
