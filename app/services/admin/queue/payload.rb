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
        SmartFolder.ensure_admin_queue_builtins!
        base = SolidQueue::Job.joins(:claimed_execution)
        active_folder = active_smart_folder
        filter = display_filter(:active, active_folder)
        jobs = filter
          .apply(base)
          .order("solid_queue_claimed_executions.created_at DESC")
          .limit(@per_page)

        smart_folder_payload(:active, base, active_folder, filter: filter).merge(
          jobs: jobs.map { |job| serialize_job(job, claimed_at: job.claimed_execution&.created_at) }
        )
      end

      def pending
        SmartFolder.ensure_admin_queue_builtins!
        active_folder = active_smart_folder
        base = SolidQueue::Job.joins(:ready_execution)
        filter = display_filter(:pending, active_folder)
        filtered = filter.apply(base)
        jobs = filtered.order("solid_queue_ready_executions.created_at ASC").limit(@per_page)

        smart_folder_payload(:pending, base, active_folder, filter: filter).merge(
          jobs: jobs.map { |job| serialize_job(job) },
          total: filtered.count
        )
      end

      def failed
        SmartFolder.ensure_admin_queue_builtins!
        since = failed_since
        active_folder = active_smart_folder
        base = SolidQueue::FailedExecution
          .includes(:job)
          .references(:job)
          .where(SolidQueue::FailedExecution.arel_table[:created_at].gteq(since))
        filter = display_filter(:failed, active_folder)
        failures = filter
          .apply(base)
          .order(created_at: :desc)
          .limit(@per_page)

        smart_folder_payload(:failed, base, active_folder, filter: filter).merge(
          since: since.iso8601,
          failures: failures.map { |failure| serialize_failure(failure) }
        )
      end

      def recurring
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

      def workers
        workers = SolidQueue::Process.where(kind: "Worker").order(:hostname, :pid)
        processes = SolidQueue::Process.order(:kind, :hostname, :pid)

        {
          workers: workers.map { |worker| serialize_worker(worker) },
          all_processes: processes.map { |process| serialize_process(process) }
        }
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

      def controls_json
        {
          filter_schema: Filters::Schema.for(subject: :admin_queue, user: user)
        }
      end

      def failed_since
        params[:since].present? ? Time.iso8601(params[:since]) : 24.hours.ago
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
