require "mcp"

module Mcp::Tools
  class ReadQueueTool < MCP::Tool
    QUEUES = %w[
      runs
      merges
      chat
      videos
      control_plane
      polling
      indexing
      cleanup
      low_priority_maintenance
    ].freeze
    PROCESS_STALE_THRESHOLD = InstanceVersion::HEARTBEAT_STALE_THRESHOLD

    tool_name "read_queue"

    description "Read a compact Solid Queue health snapshot for Syrus."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        Mcp::Tools.success(snapshot)
      rescue ActiveRecord::ActiveRecordError, ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
        Mcp::Tools.success(unavailable_snapshot(e))
      end

      private

      def snapshot
        workers = worker_rows

        {
          active_workers: {
            count: workers.count,
            queues: workers.flat_map { |worker| worker.fetch(:queues) }.uniq.sort,
            workers: workers
          },
          pending_jobs: pending_counts,
          failed_jobs: {
            count: model_count("SolidQueue::FailedExecution")
          },
          recurring_tasks: {
            count: model_count("SolidQueue::RecurringTask")
          },
          blocked_queues: blocked_queues,
          paused_queues: paused_queues
        }
      end

      def unavailable_snapshot(error)
        {
          active_workers: { count: 0, queues: [], workers: [] },
          pending_jobs: QUEUES.index_with { 0 },
          failed_jobs: { count: 0 },
          recurring_tasks: { count: 0 },
          blocked_queues: [],
          paused_queues: [],
          unavailable: true,
          error: "SolidQueue tables unreachable from this connection: #{error.message}"
        }
      end

      def worker_rows
        return [] unless model_queryable?("SolidQueue::Process")

        "SolidQueue::Process".constantize
          .where(kind: "Worker")
          .where("last_heartbeat_at > ?", PROCESS_STALE_THRESHOLD.ago)
          .order(:hostname, :pid)
          .map do |worker|
          {
            hostname: worker.hostname,
            pid: worker.pid,
            queues: worker_queues(worker),
            threads: worker.metadata&.dig("thread_pool_size"),
            last_heartbeat_at: worker.last_heartbeat_at,
            stale: false,
            status: "current",
            capabilities: process_capabilities(worker),
            capability_diagnostics: process_capability_diagnostics(worker),
            macos_worker_drain: drain_payload(worker)
          }
        end
      end

      def pending_counts
        counts = QUEUES.index_with { 0 }
        if model_queryable?("SolidQueue::ReadyExecution")
          counts.merge!("SolidQueue::ReadyExecution".constantize.group(:queue_name).count.slice(*QUEUES))
        elsif model_queryable?("SolidQueue::Job")
          counts.merge!("SolidQueue::Job".constantize.where(finished_at: nil, queue_name: QUEUES).group(:queue_name).count)
        end
        counts
      end

      def blocked_queues
        return [] unless model_queryable?("SolidQueue::BlockedExecution")

        "SolidQueue::BlockedExecution".constantize
          .distinct
          .pluck(:queue_name)
          .compact
          .sort
      rescue ActiveRecord::ActiveRecordError, ActiveRecord::StatementInvalid
        []
      end

      def paused_queues
        return [] unless model_queryable?("SolidQueue::Pause")

        "SolidQueue::Pause".constantize.distinct.order(:queue_name).pluck(:queue_name)
      rescue ActiveRecord::ActiveRecordError, ActiveRecord::StatementInvalid
        []
      end

      def model_count(model_name)
        return 0 unless model_queryable?(model_name)

        model_name.constantize.count
      end

      def model_queryable?(model_name)
        model = model_name.safe_constantize
        return false unless model&.respond_to?(:table_name)

        model.connection.table_exists?(model.table_name)
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

      def process_capabilities(process)
        WorkerCapabilities.normalize(process.metadata&.dig("capabilities").presence || instance_for_process(process)&.capabilities)
      rescue ArgumentError
        {}
      end

      def process_capability_diagnostics(process)
        process.metadata&.dig("capability_diagnostics").presence || instance_for_process(process)&.capability_diagnostics || {}
      end

      def drain_payload(process)
        drain = drains_by_identity[process_worker_storage_key(process)] || drains_by_identity[process.hostname.presence]
        drain&.directive_payload
      end

      def process_worker_storage_key(process)
        process.metadata&.dig("worker_storage_key").presence || latest_sample_by_hostname[process.hostname]&.worker_storage_key
      end

      def latest_sample_by_hostname
        @latest_sample_by_hostname ||= WorkerHostHealthSample.worker_role.order(observed_at: :desc).to_a.index_by(&:hostname)
      end

      def drains_by_identity
        @drains_by_identity ||= MacosWorkerDrain.active_by_identity
      end

      def instance_for_process(process)
        return nil if process.hostname.blank?

        worker_instances_by_hostname[process.hostname]
      end

      def worker_instances_by_hostname
        @worker_instances_by_hostname ||= InstanceVersion.fresh.where(role: "worker").index_by(&:hostname)
      end
    end
  end
end
