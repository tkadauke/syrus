module WorkerTimeline
  class LiveWorkersQuery
    attr_reader :from, :to, :hostname_filter, :status_filter

    def self.call(from:, to:, hostname: nil, status: nil)
      new(from: from, to: to, hostname: hostname, status: status).call
    end

    def initialize(from:, to:, hostname: nil, status: nil)
      @from = from
      @to = to
      @hostname_filter = hostname.presence
      @status_filter = Array(status).compact_blank.presence
    end

    def call
      workers = worker_cards.select { |worker| visible_worker?(worker) }
      {
        generated_at: Time.current.iso8601,
        range: { from: from.iso8601, to: to.iso8601 },
        attribution: {
          exact_thread_ownership: false,
          strategy: "Slots are inferred from running spawned processes, claimed worker capacity, and active Run/Workflow state."
        },
        summary: summary_for(workers),
        workers: workers
      }
    end

    private

    def worker_cards
      worker_keys.map { |key| worker_card(key) }.sort_by { |worker| [ worker[:status], worker[:hostname].to_s, worker[:worker_storage_key].to_s ] }
    end

    def worker_keys
      (
        worker_processes.map { |process| host_key_for(hostname: process.hostname) } +
        latest_samples_by_key.keys +
        instance_versions.map { |instance| host_key_for(hostname: instance.hostname) } +
        active_slots.map { |slot| slot[:worker_storage_key].presence || host_key_for(hostname: slot[:hostname]) }
      ).compact.uniq
    end

    def worker_card(key)
      host_processes = worker_processes.select { |process| host_key_for(hostname: process.hostname) == key }
      sample = latest_samples_by_key[key]
      hostname = sample&.hostname || host_processes.first&.hostname || hostname_for_key(key)
      slots = active_slots.select { |slot| slot[:worker_storage_key].presence == key || (slot[:worker_storage_key].blank? && host_key_for(hostname: slot[:hostname]) == key) }
      pools = pools_for(key, host_processes, slots)
      total_slots = pools.sum { |pool| pool[:capacity].to_i }
      total_slots = slots.length if total_slots.zero?
      health = health_payload(sample)
      status = status_for(used_slots: slots.length, total_slots: total_slots, health: health)

      {
        key: key,
        hostname: hostname,
        worker_storage_key: key,
        status: status,
        status_reasons: status_reasons(status: status, used_slots: slots.length, total_slots: total_slots, health: health),
        occupancy: { used: slots.length, total: total_slots },
        health: health,
        pools: pools,
        sparklines: sparklines_for(key)
      }
    end

    def pools_for(worker_key, host_processes, slots)
      pool_states = host_processes.map do |process|
        { process: process, queues: queue_names(process.metadata&.dig("queues")), capacity: pool_capacity(process), slots: [] }
      end

      unassigned = []
      slots.each do |slot|
        pool = best_pool_for(slot, pool_states)
        pool ? pool[:slots] << slot : unassigned << slot
      end

      pools = pool_states.map { |state| pool_payload(state) }
      return pools if unassigned.empty?

      pools + [ {
        key: "#{worker_key}:inferred",
        hostname: unassigned.first[:hostname],
        pid: nil,
        queues: [ "inferred" ],
        capacity: unassigned.length,
        used: unassigned.length,
        status: "busy",
        last_heartbeat_at: nil,
        slots: unassigned
      } ]
    end

    def best_pool_for(slot, pool_states)
      candidates = pool_states.select { |state| slot_matches_pool?(slot, state[:queues]) }
      candidates.min_by do |state|
        saturation = state[:capacity].positive? ? state[:slots].length.to_f / state[:capacity] : state[:slots].length
        [ saturation, state[:slots].length, state[:process].pid.to_i ]
      end
    end

    def pool_payload(state)
      process = state[:process]
      used = state[:slots].length
      capacity = state[:capacity]
      {
        key: "#{process.hostname}:#{process.pid}",
        hostname: process.hostname,
        pid: process.pid,
        queues: state[:queues],
        capacity: capacity,
        used: used,
        status: pool_status(used: used, capacity: capacity),
        last_heartbeat_at: process.last_heartbeat_at&.iso8601,
        slots: state[:slots]
      }
    end

    def slot_matches_pool?(slot, queues)
      return false if queues.empty?
      return true if slot[:queue_role].blank? && queues.include?("runs")

      queues.include?(slot[:queue_role].to_s)
    end

    def pool_capacity(process)
      Integer(process.metadata&.dig("thread_pool_size"), exception: false).to_i.clamp(1, 10_000)
    end

    def pool_status(used:, capacity:)
      return "overloaded" if used > capacity
      return "busy" if used.positive?

      "idle"
    end

    def status_for(used_slots:, total_slots:, health:)
      return "overloaded" if health[:level] == "critical" || used_slots > total_slots
      return "degraded" if %w[warning unknown].include?(health[:level])
      return "busy" if used_slots.positive?

      "idle"
    end

    def status_reasons(status:, used_slots:, total_slots:, health:)
      reasons = [ "#{used_slots}/#{total_slots} inferred slots occupied" ]
      reasons.concat(Array(health[:reasons]))
      reasons << "capacity exceeded" if status == "overloaded" && used_slots > total_slots
      reasons
    end

    def visible_worker?(worker)
      return false if hostname_filter.present? && worker[:hostname] != hostname_filter
      return false if status_filter && !status_filter.include?(worker[:status])

      true
    end

    def summary_for(workers)
      {
        total_workers: workers.length,
        idle: workers.count { |worker| worker[:status] == "idle" },
        busy: workers.count { |worker| worker[:status] == "busy" },
        degraded: workers.count { |worker| worker[:status] == "degraded" },
        overloaded: workers.count { |worker| worker[:status] == "overloaded" },
        used_slots: workers.sum { |worker| worker.dig(:occupancy, :used).to_i },
        total_slots: workers.sum { |worker| worker.dig(:occupancy, :total).to_i }
      }
    end

    def active_slots
      @active_slots ||= begin
        process_slots = running_processes.map { |process| slot_for_process(process) }
        process_run_ids = running_processes.filter_map(&:run_id).to_set
        process_workflow_ids = running_processes.filter_map { |process| workflow_for_process(process)&.id }.to_set
        run_slots = running_runs.reject { |run| process_run_ids.include?(run.id) }.map { |run| slot_for_run(run) }
        run_workflow_ids = running_runs.filter_map(&:workflow_id).to_set
        step_slots = running_steps.reject { |step| process_workflow_ids.include?(step.workflow_id) || run_workflow_ids.include?(step.workflow_id) }.map { |step| slot_for_step(step) }
        workflow_slot_ids = process_workflow_ids + run_workflow_ids + running_steps.map(&:workflow_id).to_set
        workflow_slots = running_workflows.reject { |workflow| workflow_slot_ids.include?(workflow.id) }.map { |workflow| slot_for_workflow(workflow) }
        (process_slots + run_slots + step_slots + workflow_slots).compact
      end
    end

    def slot_for_process(process)
      workflow = workflow_for_process(process)
      run = process.run
      step = run&.step || running_step_by_workflow_id[workflow&.id]
      job = workflow&.job || run&.job
      slot_payload(
        id: "process-#{process.id}", attribution: "spawned_process", hostname: process.hostname,
        workflow: workflow, job: job, step: step, run: run, started_at: process.started_at,
        process_id: process.id, pid: process.pid, process_kind: process.kind, command: command_excerpt(process.redacted_command)
      )
    end

    def slot_for_run(run)
      workflow = run.workflow
      slot_payload(id: "run-#{run.id}", attribution: "run", hostname: workflow&.worker_hostname, workflow: workflow, job: run.job, step: run.step, run: run, started_at: run.started_at)
    end

    def slot_for_step(step)
      workflow = step.workflow
      slot_payload(id: "step-#{step.id}", attribution: "step", hostname: workflow.worker_hostname, workflow: workflow, job: workflow.job, step: step, started_at: step.started_at)
    end

    def slot_for_workflow(workflow)
      slot_payload(id: "workflow-#{workflow.id}", attribution: "workflow", hostname: workflow.worker_hostname, workflow: workflow, job: workflow.job, started_at: workflow.started_at)
    end

    def slot_payload(id:, attribution:, hostname:, workflow:, job:, started_at:, step: nil, run: nil, process_id: nil, pid: nil, process_kind: nil, command: nil)
      {
        id: id,
        attribution: attribution,
        confidence: "inferred",
        hostname: hostname,
        worker_storage_key: workflow&.worker_storage_key.presence || host_key_for(hostname: hostname),
        queue_role: queue_role_for(workflow),
        job_id: job&.id,
        job_slug: job&.slug,
        job_title: job&.title,
        workflow_id: workflow&.id,
        workflow_slug: workflow&.slug,
        workflow_type: job&.kind,
        trigger_kind: workflow&.trigger_kind || run&.trigger_kind,
        step_id: step&.id,
        step_slug: step&.slug,
        step_kind: step&.kind,
        run_id: run&.id,
        run_slug: run&.slug,
        spawned_process_id: process_id,
        pid: pid,
        process_kind: process_kind,
        started_at: started_at&.iso8601,
        elapsed_seconds: elapsed_seconds(started_at),
        command: command,
        command_excerpt: command
      }
    end

    def workflow_for_process(process)
      process.workflow || process.run&.workflow
    end

    def queue_role_for(workflow)
      return nil unless workflow

      activity_queue_roles.fetch(workflow.id, nil) || "runs"
    end

    def activity_queue_roles
      @activity_queue_roles ||= WorkflowActivityEvent
        .where(workflow_id: running_workflows.map(&:id) + running_processes.filter_map { |process| workflow_for_process(process)&.id })
        .where.not(queue_role: nil)
        .order(:occurred_at, :id)
        .group_by(&:workflow_id)
        .transform_values { |events| events.first.queue_role }
    end

    def running_step_by_workflow_id
      @running_step_by_workflow_id ||= Step
        .where(workflow_id: running_processes.filter_map { |process| workflow_for_process(process)&.id }, state: "running")
        .order(:position, :id)
        .group_by(&:workflow_id)
        .transform_values(&:first)
    end

    def running_processes
      @running_processes ||= SpawnedProcess.running
        .includes({ workflow: :job }, run: [ :job, { step: :workflow } ])
        .then { |scope| hostname_filter ? scope.where(hostname: hostname_filter) : scope }
        .order(:started_at, :id)
        .to_a
    end

    def running_runs
      @running_runs ||= Run.where(state: "running").includes(:job, step: :workflow).order(:started_at, :id).to_a
    end

    def running_steps
      @running_steps ||= Step.where(state: "running").includes(workflow: :job).order(:started_at, :id).to_a
    end

    def running_workflows
      @running_workflows ||= Workflow.where(state: "running")
        .includes(:job)
        .then { |scope| hostname_filter ? scope.where(worker_hostname: hostname_filter) : scope }
        .order(:started_at, :id)
        .to_a
    end

    def worker_processes
      @worker_processes ||= SolidQueue::Process
        .where(kind: "Worker")
        .where("last_heartbeat_at > ?", InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago)
        .then { |scope| hostname_filter ? scope.where(hostname: hostname_filter) : scope }
        .order(:hostname, :pid)
        .to_a
    rescue NameError, ActiveRecord::StatementInvalid
      []
    end

    def instance_versions
      @instance_versions ||= InstanceVersion.fresh.where(role: "worker").then { |scope| hostname_filter ? scope.where(hostname: hostname_filter) : scope }.order(:hostname).to_a
    end

    def latest_samples_by_key
      @latest_samples_by_key ||= samples.group_by { |sample| sample_key(sample) }.transform_values(&:first)
    end

    def samples
      @samples ||= WorkerHostHealthSample.worker_role.where(observed_at: from..to).then { |scope| hostname_filter ? scope.where(hostname: hostname_filter) : scope }.order(observed_at: :desc).to_a
    end

    def health_payload(sample)
      return { level: "unknown", reasons: [ "no recent host health sample" ], observed_at: nil } unless sample

      analysis = WorkerHealthSampleAnalysis.health_for(sample)
      {
        level: analysis.fetch(:level),
        reasons: analysis.fetch(:reasons),
        observed_at: sample.observed_at&.iso8601,
        cpu_used_percent: sample.cpu_used_percent,
        memory_used_percent: sample.memory_used_percent,
        io_pressure_some: sample.io_pressure_some,
        data_root_used_percent: sample.data_root_used_percent
      }
    end

    def sparklines_for(key)
      host_samples = samples.select { |sample| sample_key(sample) == key }.reverse
      { cpu: sparkline_points(host_samples, :cpu_used_percent), memory: sparkline_points(host_samples, :memory_used_percent), io: sparkline_points(host_samples, :io_pressure_some) }
    end

    def sparkline_points(host_samples, field)
      host_samples.last(24).filter_map do |sample|
        value = sample.public_send(field)
        next if value.nil?

        { observed_at: sample.observed_at&.iso8601, value: value }
      end
    end

    def host_key_for(hostname:)
      return nil if hostname.blank?

      sample_key(latest_sample_by_hostname[hostname]) || hostname
    end

    def latest_sample_by_hostname
      @latest_sample_by_hostname ||= samples.group_by(&:hostname).transform_values(&:first)
    end

    def hostname_for_key(key)
      latest_samples_by_key[key]&.hostname || key
    end

    def sample_key(sample)
      sample&.worker_storage_key.presence || sample&.hostname
    end

    def queue_names(raw)
      InstanceVersion.queue_names(raw)
    end

    def command_excerpt(command)
      return nil if command.blank?

      CommandRedactor.redact(command).squish.truncate(180, omission: "...")
    end

    def elapsed_seconds(started_at)
      return nil unless started_at

      (Time.current - started_at).round
    end
  end
end
