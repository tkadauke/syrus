module Admin
  module Queue
    class Payload
      PER_PAGE = 100

      def initialize(params:, user:, per_page: PER_PAGE)
        @params = params
        @user = user
        @per_page = per_page
      end

      def active
        PerformanceLogging.phase("admin_queue_payload", tab: "active") do
          SmartFolder.ensure_admin_queue_builtins!
          base = SolidQueue::Job.joins(:claimed_execution)
          active_folder = active_smart_folder
          filter = display_filter(:active, active_folder)
          jobs = PerformanceLogging.phase("admin_queue.active.query") {
            filter
              .apply(base)
              .order("solid_queue_claimed_executions.created_at DESC")
              .limit(@per_page)
              .to_a
          }

          smart_folder_payload(:active, base, active_folder, filter: filter).merge(
            jobs: PerformanceLogging.phase("admin_queue.active.serialize", count: jobs.size) { jobs.map { |job| serialize_job(job, claimed_at: job.claimed_execution&.created_at) } }
          )
        end
      end

      def pending
        PerformanceLogging.phase("admin_queue_payload", tab: "pending") do
          SmartFolder.ensure_admin_queue_builtins!
          active_folder = active_smart_folder
          base = SolidQueue::Job.joins(:ready_execution)
          filter = display_filter(:pending, active_folder)
          filtered = filter.apply(base)
          jobs = PerformanceLogging.phase("admin_queue.pending.query") { filtered.order("solid_queue_ready_executions.created_at ASC").limit(@per_page).to_a }

          smart_folder_payload(:pending, base, active_folder, filter: filter).merge(
            jobs: PerformanceLogging.phase("admin_queue.pending.serialize", count: jobs.size) { jobs.map { |job| serialize_job(job) } },
            total: PerformanceLogging.phase("admin_queue.pending.total") { filtered.count }
          )
        end
      end

      def failed
        PerformanceLogging.phase("admin_queue_payload", tab: "failed") do
          SmartFolder.ensure_admin_queue_builtins!
          since = failed_since
          active_folder = active_smart_folder
          base = SolidQueue::FailedExecution
            .includes(:job)
            .references(:job)
            .where(SolidQueue::FailedExecution.arel_table[:created_at].gteq(since))
          filter = display_filter(:failed, active_folder)
          failures = PerformanceLogging.phase("admin_queue.failed.query") {
            filter
              .apply(base)
              .order(created_at: :desc)
              .limit(@per_page)
              .to_a
          }

          smart_folder_payload(:failed, base, active_folder, filter: filter).merge(
            since: since.iso8601,
            failures: PerformanceLogging.phase("admin_queue.failed.serialize", count: failures.size) { failures.map { |failure| serialize_failure(failure) } }
          )
        end
      end

      def recurring
        PerformanceLogging.phase("admin_queue_payload", tab: "recurring") do
          tasks = SolidQueue::RecurringTask.order(:key).map do |task|
            last = SolidQueue::RecurringExecution.where(task_key: task.key).order(run_at: :desc).first
            {
              key: task.key,
              class_name: task.class_name,
              schedule: task.schedule,
              last_run_at: last&.run_at,
              last_finished_at: last && SolidQueue::Job.find_by(id: last.job_id)&.finished_at
            }
          end

          { tasks: tasks }
        end
      end

      def workers
        PerformanceLogging.phase("admin_queue_payload", tab: "workers") do
          workers = PerformanceLogging.phase("admin_queue.workers.query") { SolidQueue::Process.where(kind: "Worker").order(:hostname, :pid).to_a }
          processes = PerformanceLogging.phase("admin_queue.processes.query") { SolidQueue::Process.order(:kind, :hostname, :pid).to_a }

          {
            workers: PerformanceLogging.phase("admin_queue.workers.serialize", count: workers.size) { workers.map { |worker| serialize_worker(worker) } },
            all_processes: PerformanceLogging.phase("admin_queue.processes.serialize", count: processes.size) { processes.map { |process| serialize_process(process) } },
            worker_health: PerformanceLogging.phase("admin_queue.worker_health") { ::Admin::WorkerHealthPayload.new(**worker_health_options).as_json }
          }
        end
      end

      private

      attr_reader :params, :user

      def active_smart_folder
        ::Admin::SmartFolderNavigation.active_folder(subject: :admin_queue, user: user, params: params)
      end

      def queue_filter(tab, active_folder)
        ::Admin::Queue::Filter.from_params(params, smart_folder: active_folder, user: user, tab: tab)
      end

      def display_filter(tab, active_folder)
        url_filter = ::Admin::Queue::Filter.from_params(params, user: user, tab: tab)
        return url_filter if url_filter.active? && (active_folder.nil? || params[Filters::QueryParam::PARAM_NAME].present?)

        queue_filter(tab, active_folder)
      end

      def smart_folder_payload(tab, base_scope, active_folder, filter:)
        PerformanceLogging.phase("admin_queue.smart_folders", tab: tab) do
          {
            filter: filter.to_h,
            controls: controls_json,
            active_smart_folder_id: active_folder&.id,
            smart_folders: ::Admin::SmartFolderNavigation.new(
              subject: :admin_queue,
              user: user,
              active_folder: active_folder,
              base_scope: base_scope,
              filter_class: ::Admin::Queue::Filter,
              path_context: { tab: tab }
            ).folders
          }
        end
      end

      def controls_json
        {
          filter_schema: Filters::Schema.for(subject: :admin_queue, user: user)
        }
      end

      def worker_health_options
        until_time = params[:until].presence
        since = params[:since].presence || default_worker_health_since(until_time)

        {
          since: since,
          until_time: until_time,
          sample_limit_per_host: 8,
          minute_bucket_window_minutes: params[:minute_bucket_window_minutes].presence || params[:window_minutes].presence || default_worker_health_window_minutes(since, until_time)
        }
      end

      def default_worker_health_since(until_time)
        end_time = parse_time(until_time) || Time.current
        (end_time - 2.hours).iso8601
      end

      def default_worker_health_window_minutes(since, until_time)
        start_time = parse_time(since)
        end_time = parse_time(until_time) || Time.current
        return 120 if start_time.blank?

        ((end_time - start_time) / 1.minute).ceil.clamp(1, (::Admin::WorkerHealthPayload::MAX_MINUTE_BUCKET_WINDOW / 1.minute).to_i)
      end

      def failed_since
        params[:since].present? ? Time.iso8601(params[:since]) : 24.hours.ago
      end

      def parse_time(value)
        return value if value.respond_to?(:iso8601)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def serialize_job(job, claimed_at: nil)
        {
          id: job.id,
          class_name: job.class_name,
          queue_name: job.queue_name,
          arguments: job.arguments&.dig("arguments"),
          created_at: job.created_at,
          claimed_at: claimed_at
        }
      end

      def serialize_failure(failure)
        error = failure.error || {}
        {
          id: failure.id,
          created_at: failure.created_at,
          class_name: failure.job&.class_name,
          arguments: failure.job&.arguments&.dig("arguments"),
          exception_class: error["exception_class"],
          message: error["message"]
        }
      end

      def serialize_worker(worker)
        {
          pid: worker.pid,
          hostname: worker.hostname,
          queues: worker_queues(worker),
          threads: worker.metadata&.dig("thread_pool_size"),
          last_heartbeat_at: worker.last_heartbeat_at,
          stale: worker.last_heartbeat_at.nil? || worker.last_heartbeat_at < 2.minutes.ago
        }
      end

      def worker_queues(worker)
        queues = worker.metadata&.dig("queues")

        case queues
        when Array
          queues.map(&:to_s)
        when String
          queues.split(",").map(&:strip).reject(&:blank?)
        when nil
          []
        else
          [ queues.to_s ]
        end
      end

      def serialize_process(process)
        {
          kind: process.kind,
          pid: process.pid,
          hostname: process.hostname,
          last_heartbeat_at: process.last_heartbeat_at
        }
      end
    end
  end
end
