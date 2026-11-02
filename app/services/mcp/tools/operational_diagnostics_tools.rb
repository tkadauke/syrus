require "mcp"

module Mcp::Tools::OperationalDiagnosticsTools
  module OperationalDiagnosticsToolSupport
    MAX_LANES = 50
    MAX_SPANS_PER_LANE = 100
    MAX_PENDING = 100
    MAX_WORKERS = 50
    MAX_SLOTS_PER_POOL = 100
    MAX_STALE_TERMINAL_DESCENDANTS = 100
    MAX_STEPS = 100
    MAX_RUNS_PER_STEP = 20
    MAX_TIMELINE_WINDOW = 7.days

    private

    def diagnostics_context(server_context) = McpToolContext.from_server_context(server_context)

    def diagnostics_authorized?(context, tool: self)
      return true if context.user.admin? && !context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

      McpToolRegistry.tool_permitted?(context, tool)
    end

    def diagnostics_unauthorized(context)
      message = context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) ? "Operational diagnostics access required" : "Admin access required"
      Mcp::Tools.unauthorized(message)
    end

    def diagnostics_success(source:, data:, caps: {})
      safe_data = CommandRedactor.redact_value(strip_mutation_actions(data))
      Mcp::Tools.success(generated_at: Time.current.iso8601, source: source, read_only: true, caps: caps, data: safe_data)
    end

    def visible_jobs(context)
      scope = Job.visible_to(context.user)
      if context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        scope = scope.where(repository_id: context.allowed_repository_ids)
      end
      scope
    end

    def visible_job_ids(context) = visible_jobs(context).select(:id)
    def visible_job?(context, job_id) = visible_jobs(context).where(id: job_id).exists?
    def plugin_disabled(name) = Mcp::Tools.invalid("#{name} plugin is disabled")

    def bounded_range(from:, to:)
      range_end = Time.zone.parse(to.to_s.presence || Time.current.iso8601)
      range_start = Time.zone.parse(from.to_s.presence || (range_end - 1.hour).iso8601)
      raise ArgumentError, "from and to must be valid timestamps" unless range_start && range_end
      raise ArgumentError, "from must be before to" unless range_start < range_end
      raise ArgumentError, "time range cannot exceed 7 days" if range_end - range_start > MAX_TIMELINE_WINDOW

      [ range_start, range_end ]
    end

    def strip_mutation_actions(value)
      value.except(:actions, "actions")
    end

    def cap_timeline(payload)
      lanes = Array(payload[:lanes]).first(MAX_LANES).map do |lane|
        lane.merge(spans: Array(lane[:spans]).first(MAX_SPANS_PER_LANE))
      end
      payload.merge(lanes: lanes, pending: Array(payload[:pending]).first(MAX_PENDING))
    end

    def cap_waterfall(payload)
      steps = Array(payload[:steps]).first(MAX_STEPS).map do |step|
        step.merge(runs: Array(step[:runs]).first(MAX_RUNS_PER_STEP))
      end
      payload.merge(steps: steps)
    end

    def restrict_worker_occupancy(payload, context)
      ids = visible_jobs(context).pluck(:id).to_set
      workers = Array(payload[:workers]).first(MAX_WORKERS).map do |worker|
        pools = Array(worker[:pools]).map do |pool|
          slots = Array(pool[:slots]).select { |slot| slot[:job_id].nil? || ids.include?(slot[:job_id]) }
          restrict_worker_pool(pool, slots.first(MAX_SLOTS_PER_POOL))
        end
        restrict_worker(worker, pools)
      end
      stale_descendants = Array(payload.dig(:diagnostics, :stale_terminal_descendants))
        .select { |slot| slot[:job_id].nil? || ids.include?(slot[:job_id]) }
        .first(MAX_STALE_TERMINAL_DESCENDANTS)

      payload.merge(
        summary: worker_summary(workers),
        diagnostics: payload.fetch(:diagnostics, {}).merge(stale_terminal_descendants: stale_descendants),
        workers: workers
      )
    end

    def restrict_worker_pool(pool, slots)
      used = occupied_units(slots)
      capacity = pool[:capacity]
      status = if capacity.nil?
        used.positive? ? "busy" : "idle"
      elsif used > capacity.to_i
        "overloaded"
      elsif used.positive?
        "busy"
      else
        "idle"
      end
      pool.merge(used: used, status: status, slots: slots)
    end

    def restrict_worker(worker, pools)
      slots = pools.flat_map { |pool| Array(pool[:slots]) }
      used = occupied_units(slots)
      capacity_known = pools.any? && pools.none? { |pool| pool[:capacity].nil? }
      total = capacity_known ? pools.sum { |pool| pool[:capacity].to_i } : used
      total = used if total.zero?
      health = worker.fetch(:health, {})
      status = if health[:level] == "critical" || used > total
        "overloaded"
      elsif %w[warning unknown].include?(health[:level])
        "degraded"
      elsif used.positive?
        "busy"
      else
        "idle"
      end

      worker.merge(
        status: status,
        capacity_exceeded: used > total,
        status_reasons: [ "#{used}/#{total} inferred slots occupied", *Array(health[:reasons]) ],
        occupancy: { used: used, total: total, slots: slots.length },
        pools: pools
      )
    end

    def occupied_units(slots)
      Array(slots)
        .select { |slot| %w[spawned_process run].include?(slot[:attribution].to_s) }
        .map { |slot| occupancy_key(slot) }
        .uniq
        .length
    end

    def occupancy_key(slot)
      return [ :run, slot[:run_id] ] if slot[:run_id].present?
      return [ :step, slot[:step_id] ] if slot[:step_id].present?
      return [ :workflow, slot[:workflow_id] ] if slot[:workflow_id].present?

      [ :slot, slot[:id] ]
    end

    def worker_summary(workers)
      {
        total_workers: workers.length,
        idle: workers.count { |worker| worker[:status] == "idle" },
        busy: workers.count { |worker| worker[:status] == "busy" },
        degraded: workers.count { |worker| worker[:status] == "degraded" },
        overloaded: workers.count { |worker| worker[:status] == "overloaded" },
        capacity_exceeded: workers.count { |worker| worker[:capacity_exceeded] },
        health_critical: workers.count { |worker| worker.dig(:health, :level) == "critical" },
        used_slots: workers.sum { |worker| worker.dig(:occupancy, :used).to_i },
        total_slots: workers.sum { |worker| worker.dig(:occupancy, :total).to_i }
      }
    end
  end

  class ReadMetricsDiagnosticsTool < MCP::Tool
    tool_name "read_metrics_diagnostics"
    description "Read historical queue, throughput, worker, fleet, and admission metric series. Requires the Metrics Dashboard plugin."
    input_schema(properties: { window: { type: "string", enum: %w[1h 6h 24h 7d], description: "Historical window. Defaults to 6h." } })

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, window: nil, **)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)
        plugin = "MetricsDashboard".safe_constantize
        payload_class = "MetricsDashboard::DashboardPayload".safe_constantize
        return plugin_disabled("metrics_dashboard") unless plugin&.enabled? && payload_class

        data = payload_class.build(window: window.presence || payload_class::DEFAULT_WINDOW)
        diagnostics_success(source: "MetricsDashboard::DashboardPayload", data: data)
      end
    end
  end

  class ReadWorkerOccupancyTool < MCP::Tool
    tool_name "read_worker_occupancy"
    description "Read live worker occupancy, capacity, and attributed active slots for a bounded time range. Requires the Worker Timeline plugin."
    input_schema(properties: {
      from: { type: "string", description: "Optional ISO8601 range start; defaults to one hour before to." },
      to: { type: "string", description: "Optional ISO8601 range end; defaults to now." },
      hostname: { type: "string", description: "Optional exact hostname filter." },
      status: { type: "array", items: { type: "string" }, description: "Optional worker status filters." }
    })

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, from: nil, to: nil, hostname: nil, status: nil, **)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)
        plugin = "WorkerTimeline".safe_constantize
        query = "WorkerTimeline::LiveWorkersQuery".safe_constantize
        return plugin_disabled("worker_timeline") unless plugin&.enabled? && query

        range_start, range_end = bounded_range(from:, to:)
        data = query.call(from: range_start, to: range_end, hostname: hostname, status: status)
        data = restrict_worker_occupancy(data, context)
        diagnostics_success(
          source: "WorkerTimeline::LiveWorkersQuery", data: data,
          caps: {
            workers: MAX_WORKERS, slots_per_pool: MAX_SLOTS_PER_POOL,
            stale_terminal_descendants: MAX_STALE_TERMINAL_DESCENDANTS
          }
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end

  class ReadWorkflowTimelineTool < MCP::Tool
    tool_name "read_workflow_timeline"
    description "Read bounded worker lanes with Job and Workflow attribution, filtered to repositories visible to the caller. Requires the Worker Timeline plugin."
    input_schema(properties: {
      from: { type: "string", description: "Optional ISO8601 range start; defaults to one hour before to." },
      to: { type: "string", description: "Optional ISO8601 range end; defaults to now." },
      repository_id: { type: "integer", description: "Optional repository id." },
      hostname: { type: "string", description: "Optional exact hostname." },
      job_id: { type: "integer", description: "Optional Job id." },
      status: { type: "array", items: { type: "string" }, description: "Optional Workflow status filters." }
    })

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, **arguments)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)
        plugin = "WorkerTimeline".safe_constantize
        return plugin_disabled("worker_timeline") unless plugin&.enabled?

        range_start, range_end = bounded_range(from: arguments[:from], to: arguments[:to])
        filters = arguments.slice(:repository_id, :hostname, :job_id, :status)
        data = Timeline::MacroQuery.call(**filters, from: range_start, to: range_end, allowed_job_ids: visible_job_ids(context))
        diagnostics_success(
          source: "Timeline::MacroQuery", data: cap_timeline(data),
          caps: { lanes: MAX_LANES, spans_per_lane: MAX_SPANS_PER_LANE, pending: MAX_PENDING }
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end

  class ReadWorkflowWaterfallTool < MCP::Tool
    tool_name "read_workflow_waterfall"
    description "Read Step and Run attribution for one visible Workflow. Requires the Worker Timeline plugin."
    input_schema(properties: { workflow_id: { type: "integer", description: "Workflow id." } }, required: [ "workflow_id" ])

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, workflow_id:, **)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)
        plugin = "WorkerTimeline".safe_constantize
        return plugin_disabled("worker_timeline") unless plugin&.enabled?

        workflow = Workflow.select(:id, :job_id).find_by(id: workflow_id)
        return Mcp::Tools.invalid("workflow not found or not visible") unless workflow && visible_job?(context, workflow.job_id)

        data = Timeline::WorkflowWaterfallQuery.call(workflow_id: workflow.id)
        diagnostics_success(
          source: "Timeline::WorkflowWaterfallQuery", data: cap_waterfall(data),
          caps: { steps: MAX_STEPS, runs_per_step: MAX_RUNS_PER_STEP }
        )
      end
    end
  end

  class ReadAdmissionDiagnosticsTool < MCP::Tool
    tool_name "read_admission_diagnostics"
    description "Read delayed work, admission reasons, resource consumers, confidence profiles, and overrides visible to the caller."
    input_schema(properties: {})

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, **)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)

        data = Admin::ResourceAdmissionDiagnosticsPayload.new.as_json
        coworker_role = context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        data = restrict_admission_payload(data, context) unless context.user.admin? && !coworker_role
        diagnostics_success(source: "Admin::ResourceAdmissionDiagnosticsPayload", data: data)
      end

      private

      def restrict_admission_payload(payload, context)
        scoped_jobs = visible_jobs(context)
        ids = scoped_jobs.pluck(:id).to_set
        repository_slugs = Repository.where(id: scoped_jobs.select(:repository_id)).pluck(:owner, :name).map { |owner, name| "#{owner}/#{name}" }.to_set
        payload.merge(
          active_consumers: visible_rows(payload[:active_consumers], ids),
          recent_top_consumers: visible_rows(payload[:recent_top_consumers], ids),
          delayed_work: visible_rows(payload[:delayed_work], ids),
          low_confidence_profiles: Array(payload[:low_confidence_profiles]).select { |row| repository_slugs.include?(row[:repository]) },
          admission_overrides: visible_rows(payload[:admission_overrides], ids)
        )
      end

      def visible_rows(rows, ids) = Array(rows).select { |row| ids.include?(row[:job_id]) }
    end
  end

  class DiagnoseRunQueueTool < MCP::Tool
    tool_name "diagnose_run_queue"
    description "Explain why one visible queued Run has not started, using the existing queue diagnosis service."
    input_schema(properties: { run_id: { type: "integer", description: "Run id." } }, required: [ "run_id" ])

    class << self
      include OperationalDiagnosticsToolSupport

      def call(server_context:, run_id:, **)
        context = diagnostics_context(server_context)
        return diagnostics_unauthorized(context) unless diagnostics_authorized?(context)

        run = Run.includes(step: :workflow).find_by(id: run_id)
        return Mcp::Tools.invalid("run not found or not visible") unless run && visible_job?(context, run.job_id)

        diagnostics_success(source: "RunQueueDiagnosis", data: { run_id: run.id, diagnosis: RunQueueDiagnosis.call(run) })
      end
    end
  end
end
