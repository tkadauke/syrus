module WorkerTimeline
  class LiveWorkersPayload
    HEALTH_SAMPLE_LIMIT = 18
    PROCESS_STALE_THRESHOLD = InstanceVersion::HEARTBEAT_STALE_THRESHOLD
    LIVE_PROCESS_KINDS = %w[ agent grader git prepare format generate builder dependency_audit deploy ].freeze

    def self.call(filter:)
      new(filter: filter).call
    end

    def initialize(filter:)
      @filter = filter
    end

    def call
      hosts = host_keys.map { |key| host_payload(key) }.compact

      {
        generated_at: Time.current.iso8601,
        summary: summary(hosts),
        hosts: hosts,
        filter: filter.to_h,
        filter_schema: WorkerTimeline::MacroQueryFilter.schema
      }
    end

    private

    attr_reader :filter

    def host_payload(key)
      identity = identities.fetch(key, {})
      hostname = identity[:hostname] || key
      slots = slots_for(key)
      return nil if job_scoped_filter? && slots.empty?
      return nil if filtered_out_by_status?(slots)

      pools = pools_for(key)
      latest_sample = latest_sample_by_key[key]
      health = health_for(identity: identity, sample: latest_sample)
      state = host_state(slots: slots, pools: pools, health: health)

      {
        key: key,
        hostname: hostname,
        worker_storage_key: identity[:worker_storage_key],
        state: state,
        health: health,
        started_at: identity[:started_at]&.iso8601,
        last_heartbeat_at: identity[:last_heartbeat_at]&.iso8601,
        version: identity[:version],
        pools: pools,
        slots: slots,
        sparklines: sparklines_for(key)
      }
    end

    def summary(hosts)
      states = hosts.group_by { |host| host.fetch(:state) }
      {
        total_hosts: hosts.length,
        idle_hosts: states.fetch("idle", []).length,
        busy_hosts: states.fetch("busy", []).length,
        degraded_hosts: states.fetch("degraded", []).length,
        overloaded_hosts: states.fetch("overloaded", []).length,
        active_slots: hosts.sum { |host| host.fetch(:slots).count { |slot| slot.fetch(:state) == "active" } },
        total_slots: hosts.sum { |host| host.fetch(:pools).sum { |pool| pool.fetch(:threads).to_i } }
      }
    end

    def host_state(slots:, pools:, health:)
      return "overloaded" if health.fetch(:level) == "critical"

      capacity = pools.sum { |pool| pool.fetch(:threads).to_i }
      active = slots.count { |slot| slot.fetch(:state) == "active" }
      return "overloaded" if capacity.positive? && active > capacity
      return "degraded" if health.fetch(:level) == "warning" || health.fetch(:level) == "unknown"
      return "busy" if active.positive?

      "idle"
    end

    def filtered_out_by_status?(slots)
      status_values = Array(filter.status).compact_blank
      return false if status_values.empty?

      slots.none? { |slot| status_values.include?(slot.fetch(:workflow).fetch(:status)) || status_values.include?(slot.fetch(:run).fetch(:status).to_s) }
    end

    def job_scoped_filter?
      filter.repository_id.present? || filter.epic_id.present? || Array(filter.job_type).compact_blank.any?
    end

    def host_keys
      @host_keys ||= (identities.keys + pools_by_key.keys + running_processes_by_key.keys + active_runs_by_key.keys + latest_sample_by_key.keys).uniq.sort.select do |key|
        filter.hostname.blank? || identities.dig(key, :hostname) == filter.hostname || key == filter.hostname
      end
    end

    def identities
      @identities ||= begin
        result = {}
        current_instances.each do |instance|
          sample = latest_sample_by_hostname[instance.hostname]
          key = sample&.worker_storage_key.presence || instance.hostname
          result[key] = {
            hostname: instance.hostname,
            worker_storage_key: sample&.worker_storage_key.presence,
            started_at: instance.started_at,
            last_heartbeat_at: instance.last_heartbeat_at,
            version: instance.version,
            stale: instance.stale?
          }
        end
        latest_sample_by_key.each do |key, sample|
          result[key] ||= {
            hostname: sample.hostname,
            worker_storage_key: sample.worker_storage_key.presence,
            started_at: nil,
            last_heartbeat_at: nil,
            version: sample.version,
            stale: false
          }
        end
        active_run_identity_by_key.each do |key, payload|
          result[key] ||= payload
        end
        result
      end
    end

    def active_run_identity_by_key
      @active_run_identity_by_key ||= active_runs_by_key.transform_values do |runs|
        workflow = runs.first.workflow
        {
          hostname: workflow&.worker_hostname,
          worker_storage_key: workflow&.worker_storage_key.presence,
          started_at: nil,
          last_heartbeat_at: nil,
          version: nil,
          stale: false
        }
      end
    end

    def current_instances
      @current_instances ||= InstanceVersion.fresh.where(role: "worker").order(:hostname).to_a
    end

    def pools_for(key)
      pools_by_key.fetch(key, []).map do |process|
        {
          hostname: process.hostname,
          pid: process.pid,
          queues: queue_names(process),
          threads: pool_thread_count(process),
          last_heartbeat_at: process.last_heartbeat_at&.iso8601,
          stale: process_stale?(process)
        }
      end
    end

    def pools_by_key
      @pools_by_key ||= fresh_worker_processes.group_by { |process| key_for_hostname(process.hostname) }
    end

    def fresh_worker_processes
      @fresh_worker_processes ||= SolidQueue::Process
        .where(kind: [ "Worker", "worker" ])
        .where("last_heartbeat_at > ?", PROCESS_STALE_THRESHOLD.ago)
        .order(:hostname, :pid)
        .to_a
    rescue ActiveRecord::StatementInvalid
      []
    end

    def slots_for(key)
      running_processes_by_key.fetch(key, []).map { |process| process_slot_payload(process) } +
        active_runs_by_key.fetch(key, []).map { |run| run_slot_payload(run) }
    end

    def process_slot_payload(process)
      run = process.run
      step = run&.step
      workflow = process.workflow || step&.workflow || run&.workflow
      job = workflow&.job || run&.job

      {
        id: process.id,
        state: "active",
        attribution_confidence: attribution_confidence(process, run, workflow),
        attribution_note: attribution_note(process, run, workflow),
        spawned_process: {
          id: process.id,
          pid: process.pid,
          kind: process.kind,
          started_at: process.started_at&.iso8601,
          elapsed_s: process.duration_s.round(1),
          command_excerpt: command_excerpt(process)
        },
        job: {
          id: job&.id,
          slug: job && App::Presentation.job_slug(job),
          title: job&.title
        },
        workflow: {
          id: workflow&.id,
          slug: workflow&.slug,
          trigger_kind: workflow&.trigger_kind,
          type: workflow&.chain_template,
          status: workflow&.state
        },
        step: {
          id: step&.id,
          kind: step&.kind,
          status: step&.state
        },
        run: {
          id: run&.id,
          status: run&.state,
          trigger_kind: run&.trigger_kind
        }
      }
    end

    def run_slot_payload(run)
      step = run.step
      workflow = step&.workflow
      job = workflow&.job || run.job

      {
        id: "run-#{run.id}",
        state: "active",
        attribution_confidence: "run_state",
        attribution_note: "Inferred from an active Run/Workflow row; no live SpawnedProcess is linked, and exact thread ownership is not instrumented.",
        spawned_process: {
          id: nil,
          pid: nil,
          kind: nil,
          started_at: run.started_at&.iso8601,
          elapsed_s: run.started_at ? (Time.current - run.started_at).round(1) : 0,
          command_excerpt: "No running subprocess is currently linked."
        },
        job: {
          id: job&.id,
          slug: job && App::Presentation.job_slug(job),
          title: job&.title
        },
        workflow: {
          id: workflow&.id,
          slug: workflow&.slug,
          trigger_kind: workflow&.trigger_kind,
          type: workflow&.chain_template,
          status: workflow&.state
        },
        step: {
          id: step&.id,
          kind: step&.kind,
          status: step&.state
        },
        run: {
          id: run.id,
          status: run.state,
          trigger_kind: run.trigger_kind
        }
      }
    end

    def running_processes_by_key
      @running_processes_by_key ||= begin
        processes = SpawnedProcess
          .running
          .where(kind: LIVE_PROCESS_KINDS)
          .includes(:run, workflow: :job)
          .order(:hostname, :started_at, :id)
          .to_a

        ActiveRecord::Associations::Preloader.new(records: processes.filter_map(&:run), associations: [ :job, { step: { workflow: :job } } ]).call
        processes.select { |process| process_visible?(process) }.group_by { |process| key_for_hostname(process.hostname) }
      end
    end

    def active_runs_by_key
      @active_runs_by_key ||= Run
        .where(state: "running")
        .where.not(id: run_ids_with_process)
        .includes(:job, step: { workflow: :job })
        .to_a
        .select { |run| active_run_visible?(run) }
        .group_by { |run| run_key(run) }
    end

    def active_run_visible?(run)
      workflow = run.workflow
      return false if workflow.blank?
      return false if run_key(run).blank?

      job = workflow.job || run.job
      return false if filter.repository_id.present? && job&.repository_id.to_i != filter.repository_id.to_i
      return false if filter.epic_id.present? && job&.epic_id.to_i != filter.epic_id.to_i
      return false if filter.job_type.present? && !job_type_values.include?(job&.kind)

      true
    end

    def run_ids_with_process
      @run_ids_with_process ||= SpawnedProcess.running.where.not(run_id: nil).distinct.pluck(:run_id)
    end

    def process_visible?(process)
      run = process.run
      workflow = process.workflow || run&.workflow
      job = workflow&.job || run&.job
      return false if filter.repository_id.present? && job&.repository_id.to_i != filter.repository_id.to_i
      return false if filter.epic_id.present? && job&.epic_id.to_i != filter.epic_id.to_i
      return false if filter.job_type.present? && !job_type_values.include?(job&.kind)

      true
    end

    def job_type_values
      @job_type_values ||= {
        "system" => Filters::Chips::Jobs::JobType.system_kinds,
        "user" => Filters::Chips::Jobs::JobType.user_kinds
      }.values_at(*Array(filter.job_type)).flatten.compact.uniq
    end

    def health_for(identity:, sample:)
      reasons = []
      level = "ok"

      if identity[:stale]
        level = WorkerHealthSampleAnalysis.max_level(level, "critical")
        reasons << "worker heartbeat stale"
      end

      if sample.nil?
        return { level: "unknown", reasons: reasons.presence || [ "no recent host health sample" ] }
      end

      if sample.observed_at < Admin::WorkerHealthPayload::CURRENT_SAMPLE_WINDOW.ago
        level = WorkerHealthSampleAnalysis.max_level(level, "warning")
        reasons << "host health sample older than #{Admin::WorkerHealthPayload::CURRENT_SAMPLE_WINDOW.to_i} seconds"
      end

      sample_health = WorkerHealthSampleAnalysis.health_for(sample)
      level = WorkerHealthSampleAnalysis.max_level(level, sample_health.fetch(:level))
      reasons.concat(sample_health.fetch(:reasons))

      { level: level, reasons: reasons }
    end

    def latest_sample_by_hostname
      @latest_sample_by_hostname ||= recent_samples.group_by(&:hostname).transform_values(&:first)
    end

    def latest_sample_by_key
      @latest_sample_by_key ||= recent_samples.group_by { |sample| sample.worker_storage_key.presence || sample.hostname }.transform_values(&:first)
    end

    def samples_by_key
      @samples_by_key ||= recent_samples.group_by { |sample| sample.worker_storage_key.presence || sample.hostname }
    end

    def recent_samples
      @recent_samples ||= WorkerHostHealthSample
        .worker_role
        .where("observed_at >= ?", 2.hours.ago)
        .order(observed_at: :desc)
        .to_a
    end

    def sparklines_for(key)
      samples = samples_by_key.fetch(key, []).sort_by(&:observed_at).last(HEALTH_SAMPLE_LIMIT)
      {
        cpu: sparkline(samples, :cpu_used_percent),
        memory: sparkline(samples, :memory_used_percent),
        io: sparkline(samples, :io_pressure_some)
      }
    end

    def sparkline(samples, field)
      samples.map do |sample|
        {
          at: sample.observed_at&.iso8601,
          value: sample.public_send(field)
        }
      end
    end

    def attribution_confidence(process, run, workflow)
      return "run" if process.run_id.present? && run
      return "workflow" if process.workflow_id.present? && workflow

      "process"
    end

    def attribution_note(process, run, workflow)
      return "SpawnedProcess is linked to this Run." if process.run_id.present? && run
      return "SpawnedProcess is linked to this Workflow; exact thread ownership is not instrumented." if process.workflow_id.present? && workflow

      "Inferred from a running process on this worker; exact thread ownership is not instrumented."
    end

    def command_excerpt(process)
      process.redacted_command.to_s.squish.truncate(160)
    end

    def queue_names(process)
      InstanceVersion.queue_names(process.metadata&.dig("queues"))
    end

    def pool_thread_count(process)
      Integer(process.metadata&.dig("thread_pool_size"), exception: false) || 1
    end

    def process_stale?(process)
      process.last_heartbeat_at.nil? || process.last_heartbeat_at < PROCESS_STALE_THRESHOLD.ago
    end

    def key_for_hostname(hostname)
      sample = latest_sample_by_hostname[hostname]
      sample&.worker_storage_key.presence || hostname
    end

    def run_key(run)
      workflow = run.workflow
      workflow&.worker_storage_key.presence || key_for_hostname(workflow&.worker_hostname)
    end
  end
end
