module Timeline
  # Read-only micro (single-Workflow waterfall) query backing the
  # worker-activity-timeline plugin's drill-down view: ordered Steps with
  # their Runs. Step/Run carry no host column of their own, so every row
  # is attributed to the parent Workflow's worker lane via
  # WorkerAttribution -- the same resolver Timeline::MacroQuery uses.
  #
  # Steps have no blocked-reason machinery of their own -- only the
  # Workflow does (via its WorkUnit / start_blocked_* artifacts). A Step
  # that hasn't started yet is either waiting on the Workflow itself to
  # start (the same reason MacroQuery reports for a pending Workflow) or
  # simply queued behind an earlier Step in the same running Workflow (no
  # separate reason to report). Either way, the one blocked-reason source
  # available is the Workflow's, via BlockedExplanation -- so every
  # not-yet-started Step payload carries the same memoized
  # `workflow_blocked` value the top-level `workflow` payload does, rather
  # than fabricating a per-step explanation.
  class WorkflowWaterfallQuery
    def self.call(workflow_id:) = new(workflow_id: workflow_id).call

    def initialize(workflow_id:)
      @workflow = Workflow.includes(steps: { runs: :command_spans }).find(workflow_id)
    end

    def call
      {
        workflow: workflow_payload,
        steps: steps.map { |step| step_payload(step) }
      }
    end

    private

    attr_reader :workflow

    def attribution
      @attribution ||= WorkerAttribution.for_workflows([ workflow ]).fetch(workflow.id)
    end

    def steps
      @steps ||= workflow.steps.to_a
    end

    def workflow_payload
      {
        id: workflow.id,
        job_id: workflow.job_id,
        trigger_kind: workflow.trigger_kind,
        status: workflow.state,
        started_at: workflow.started_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601,
        worker_storage_key: attribution[:worker_storage_key],
        queue_role: attribution[:queue_role],
        hostname: attribution[:hostname],
        pid: attribution[:pid],
        blocked: workflow_blocked
      }
    end

    def step_payload(step)
      payload = {
        id: step.id,
        kind: step.kind,
        status: step.state,
        position: step.position,
        iteration: step.iteration,
        started_at: step.started_at&.iso8601,
        finished_at: step.finished_at&.iso8601,
        placement: step_placement_payload(step),
        source_snapshot: step_source_snapshot_payload(step),
        worker: step_worker_payload(step),
        prepare_cache: step_prepare_cache_payload(step),
        admission_block: step_admission_block_payload(step),
        barrier: step_barrier_payload(step),
        worker_storage_key: attribution[:worker_storage_key],
        queue_role: attribution[:queue_role],
        hostname: attribution[:hostname],
        pid: attribution[:pid],
        runs: step.runs.map { |run| run_payload(run) }
      }
      payload[:blocked] = workflow_blocked if step.started_at.nil?
      payload
    end

    def workflow_blocked
      @workflow_blocked ||= BlockedExplanation.for(workflow)
    end

    def run_payload(run)
      {
        id: run.id,
        status: run.state,
        iteration: run.iteration,
        started_at: run.started_at&.iso8601,
        finished_at: run.finished_at&.iso8601,
        last_heartbeat_at: run.last_heartbeat_at&.iso8601,
        command_spans: run.command_spans.map { |span| command_span_payload(span) }
      }
    end

    def step_placement_payload(step)
      {
        policy: step.placement_policy,
        projected_target_label: string_presence(step.details.to_h["projected_target_label"]),
        projected_target_fingerprint: string_presence(step.details.to_h["projected_target_fingerprint"]),
        projected_resource_key: string_presence(step.details.to_h["projected_resource_key"])
      }.compact
    end

    def step_source_snapshot_payload(step)
      snapshot = step.details.to_h["source_snapshot"].to_h
      snapshot_id = step.details.to_h["source_snapshot_id"].presence || snapshot["id"].presence
      return nil if snapshot_id.blank? && snapshot.blank?

      {
        id: snapshot_id,
        source_sha: string_presence(snapshot["source_sha"]),
        source_ref: string_presence(snapshot["source_ref"]),
        tree_sha: string_presence(snapshot["tree_sha"]),
        fingerprint: string_presence(snapshot["fingerprint"])
      }.compact
    end

    def step_worker_payload(step)
      checkout = step.details.to_h["immutable_source_checkout"].to_h
      slot = worker_slots_by_step_id.fetch(step.id, []).last
      hostname = checkout["worker_hostname"].presence || slot&.worker_hostname.presence || attribution[:hostname]
      storage_key = checkout["worker_storage_key"].presence || slot&.worker_storage_key.presence || attribution[:worker_storage_key]
      return nil if hostname.blank? && storage_key.blank?

      {
        hostname: hostname,
        storage_key: storage_key,
        slot_acquired_at: slot&.acquired_at&.iso8601,
        slot_released_at: slot&.released_at&.iso8601,
        slot_release_reason: string_presence(slot&.release_reason)
      }.compact
    end

    def step_prepare_cache_payload(step)
      cache = step.details.to_h["prepare_cache"].to_h
      return nil if cache.blank?

      {
        status: string_presence(cache["status"]),
        cache_key: string_presence(cache["cache_key"]),
        short_cache_key: string_presence(cache["short_cache_key"]),
        worker_storage_key: string_presence(cache["worker_storage_key"]),
        prepare_fingerprint: string_presence(cache["prepare_fingerprint"]),
        source_snapshot_id: cache["source_snapshot_id"].presence,
        source_snapshot_sha: string_presence(cache["source_snapshot_sha"]),
        recorded_at: string_presence(cache["recorded_at"])
      }.compact
    end

    def step_admission_block_payload(step)
      candidates = [
        [ "workflow_step_worker_slot_admission", workflow.artifact("workflow_step_worker_slot_admission").to_h ],
        [ "run_host_admission", workflow.artifact("run_host_admission").to_h ],
        [ "start_blocked_details", workflow.artifact("start_blocked_details").to_h ],
        [ "workflow_admission_decision", workflow.artifact("workflow_admission_decision").to_h ]
      ]
      key, details = candidates.find { |_candidate_key, candidate| admission_block_matches_step?(candidate, step) }
      return nil unless details.present?

      {
        source: key,
        reason: string_presence(details["reason"]),
        action: string_presence(details["action"]),
        retry_at: string_presence(details["retry_at"]),
        deferred_at: string_presence(details["deferred_at"]),
        phase_step_id: details["phase_step_id"].presence || details["step_id"].presence,
        phase_step_kind: string_presence(details["phase_step_kind"] || details["step_kind"])
      }.compact
    end

    def admission_block_matches_step?(details, step)
      step_id = details["phase_step_id"].presence || details["step_id"].presence
      step_id.to_i == step.id
    end

    def step_barrier_payload(step)
      labels = Array(step.details.to_h["barrier_labels"]).filter_map { |label| string_presence(label) }
      group = string_presence(step.details.to_h["barrier_group"])
      waiting_on_ids = step.depends_on_step_ids
      return nil if labels.empty? && group.blank? && waiting_on_ids.empty? && !step.kind.to_s.end_with?("_collect")

      dependency_steps = waiting_on_ids.empty? ? [] : steps.select { |candidate| waiting_on_ids.include?(candidate.id) }
      completed = dependency_steps.count(&:terminal?)
      {
        group: group,
        labels: labels,
        waiting_on_step_ids: waiting_on_ids,
        completed_count: completed,
        total_count: dependency_steps.size,
        pending_count: [ dependency_steps.size - completed, 0 ].max
      }.compact
    end

    def command_span_payload(span)
      {
        id: span.id,
        run_id: span.run_id,
        job_id: span.job_id,
        workflow_id: span.workflow_id,
        step_id: span.step_id,
        spawned_process_id: span.spawned_process_id,
        sequence: span.sequence,
        name: span.name,
        command_excerpt: CommandRedactor.redact(span.command_excerpt),
        started_at: span.started_at&.iso8601,
        finished_at: span.finished_at&.iso8601,
        duration_ms: span.duration_ms,
        duration_s: span.duration_s,
        exit_status: span.exit_status,
        outcome: span.outcome,
        hostname: span.hostname,
        metadata: CommandRedactor.redact_value(span.metadata),
        sample_count: 0,
        samples_missing: true,
        retention_limited: false,
        summary: {},
        pressure: {
          level: "unknown",
          reasons: [ "worker health correlation is loaded on demand" ]
        }
      }
    end

    def worker_slots_by_step_id
      @worker_slots_by_step_id ||= begin
        ids = steps.map(&:id)
        ids.empty? ? {} : WorkflowStepWorkerSlot.where(step_id: ids).order(:step_id, :acquired_at, :id).group_by(&:step_id)
      end
    end

    def string_presence(value)
      value.to_s.presence if value.present?
    end
  end
end
