module Timeline
  # Read-only macro (multi-lane worker activity) query backing the
  # worker-activity-timeline plugin. Given a time range and filters,
  # groups Workflow spans into lanes keyed by the durable worker lane
  # (worker_storage_key+queue_role) that ran them, resolved via WorkerAttribution, and
  # layers in InstanceVersion so a worker that was alive but idle for the
  # whole window still gets a lane.
  #
  # Workflows that haven't started yet (no lane to place them in) are
  # reported separately under `pending`, along with why they're still
  # waiting via WorkUnits::StartBlock#explanation -- the same blocked-reason
  # source Admin::StuckJobExplainer uses, so this doesn't reimplement the
  # WorkUnit/admission-block lookup. A queued Workflow older than
  # STALE_PENDING_THRESHOLD is dropped from `pending` entirely -- it's not
  # going to start any time soon and just clutters the "waiting to start"
  # list; it's still reachable through the Job/Workflow admin views.
  class MacroQuery
    DEFAULT_WINDOW = 1.hour
    STALE_PENDING_THRESHOLD = 1.week
    JOB_TYPE_ALIASES = {
      "infra" => "system",
      "infrastructure" => "system",
      "system" => "system",
      "user" => "user"
    }.freeze

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(from: nil, to: nil, repository_id: nil, epic_id: nil, job_id: nil, hostname: nil, status: nil, job_type: nil, expression: nil, allowed_job_ids: nil)
      @to = parse_time(to) || Time.current
      @from = parse_time(from) || (@to - DEFAULT_WINDOW)
      @repository_id = repository_id.presence
      @epic_id = epic_id.presence
      @job_id = job_id.presence
      @hostname_filter = hostname.presence
      @status_filter = Array(status).flat_map { |value| value.to_s.split(",") }.compact_blank.presence
      @job_type_filter = Array(job_type)
        .flat_map { |value| value.to_s.split(",") }
        .filter_map { |value| JOB_TYPE_ALIASES[value.to_s] }
        .uniq
      @job_type_filter = @job_type_filter.presence
      @expression = expression
      @allowed_job_ids = allowed_job_ids
    end

    def call
      active_lanes = lanes_payload
      active_hostnames = active_lanes.map { |lane| lane[:hostname] }.compact

      {
        range: { from: from.iso8601, to: to.iso8601 },
        lanes: (active_lanes + idle_lanes_payload(active_hostnames)).sort_by { |lane| lane[:key].to_s },
        pending: pending_payload
      }
    end

    # Count the same visible entries as #call without constructing lane/span
    # payloads or blocked explanations. Evaluation stops at limit + 1 matches
    # so SmartFolder navigation can report a capped count at bounded cost.
    def capped_count(limit: SmartFolder::COUNT_CAP)
      stop_at = limit + 1
      count = 0
      active_hostnames = Set.new

      each_batch(workflow_scope.includes(:job), stop_at) do |batch|
        attributions = WorkerAttribution.for_workflows(batch)
        batch.each do |workflow|
          attribution = attributions.fetch(workflow.id)
          next if hostname_filter && attribution[:hostname] != hostname_filter
          next if expression && !expression.matches_workflow?(workflow, source: :span, attribution: attribution)

          active_hostnames << attribution[:hostname] if attribution[:hostname].present?
          count += 1
          return capped_count_result(count, limit) if count >= stop_at
        end
      end

      each_batch(pending_workflow_scope.includes(:job), stop_at - count) do |batch|
        batch.each do |workflow|
          next if expression && !expression.matches_workflow?(workflow, source: :pending)

          count += 1
          return capped_count_result(count, limit) if count >= stop_at
        end
      end

      idle_hostnames = Set.new
      each_batch(instance_version_scope, stop_at - count) do |batch|
        batch.each do |instance|
          next if active_hostnames.include?(instance.hostname) || idle_hostnames.include?(instance.hostname)
          next if expression && !expression.matches_instance?(instance)

          idle_hostnames << instance.hostname
          count += 1
          return capped_count_result(count, limit) if count >= stop_at
        end
      end

      capped_count_result(count, limit)
    end

    private

    attr_reader :from, :to, :repository_id, :epic_id, :job_id, :hostname_filter, :status_filter, :job_type_filter, :expression, :allowed_job_ids

    def lanes_payload
      spans.group_by { |span| span[:lane_key] }.map do |_lane_key, lane_spans|
        representative_span = lane_spans.max_by { |span| span[:started_at] }
        {
          key: lane_payload_key(representative_span[:lane_key]),
          worker_storage_key: representative_span[:worker_storage_key],
          queue_role: representative_span[:queue_role],
          hostname: representative_span[:hostname],
          pid: representative_span[:pid],
          instance: instance_payload(instance_for_hostname(representative_span[:hostname])),
          spans: lane_spans.sort_by { |span| span[:started_at] }.map { |span| span.except(:lane_key) }
        }
      end
    end

    def idle_lanes_payload(active_hostnames)
      instance_versions.reject { |instance| active_hostnames.include?(instance.hostname) }
        .group_by(&:hostname)
        .map do |hostname, instances|
          {
            key: lane_payload_key([ "idle", hostname ]),
            worker_storage_key: nil,
            queue_role: nil,
            hostname: hostname,
            pid: nil,
            instance: instance_payload(instances.max_by(&:started_at)),
            spans: []
          }
        end
    end

    def spans
      @spans ||= workflows.filter_map { |workflow| span_for(workflow) }
    end

    def span_for(workflow)
      attribution = attribution_for(workflow)
      return nil if hostname_filter && attribution[:hostname] != hostname_filter
      return nil if expression && !expression.matches_workflow?(workflow, source: :span, attribution: attribution)

      {
        lane_key: lane_key_for(attribution),
        worker_storage_key: attribution[:worker_storage_key],
        queue_role: attribution[:queue_role],
        hostname: attribution[:hostname],
        pid: attribution[:pid],
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        started_at: workflow.started_at.iso8601,
        finished_at: workflow.finished_at&.iso8601,
        status: workflow.state,
        label: label_for(workflow),
        job_title: job_title_for(workflow),
        blocked: blocked_payload(workflow)
      }
    end

    def pending_payload
      pending_workflows.filter_map do |workflow|
        next if expression && !expression.matches_workflow?(workflow, source: :pending)
        {
          workflow_id: workflow.id,
          job_id: workflow.job_id,
          label: label_for(workflow),
          job_title: job_title_for(workflow),
          created_at: workflow.created_at&.iso8601,
          blocked: blocked_payload(workflow)
        }
      end
    end

    # Reused on both spans (hover: "why did this take so long to start?")
    # and pending entries (hover: "why hasn't this started yet?") -- see
    # WorkUnits::StartBlock#explanation for why `available: false` there
    # means "no record survives", not "nothing ever blocked this". Shaping
    # itself lives in BlockedExplanation, shared with WorkflowWaterfallQuery.
    def blocked_payload(workflow)
      BlockedExplanation.for(workflow)
    end

    def workflows
      @workflows ||= workflow_scope.includes(:job, :work_unit).order(:started_at).to_a
    end

    def pending_workflows
      @pending_workflows ||= pending_workflow_scope.includes(:job, :work_unit).order(:created_at).to_a
    end

    def workflow_scope
      scope = Workflow.where.not(started_at: nil)
        .where("workflows.started_at < ?", to)
        .where("workflows.finished_at IS NULL OR workflows.finished_at > ?", from)
      scope = apply_filters(scope)
      scope = scope.where(job_id: allowed_job_ids) if allowed_job_ids
      scope = scope.where(state: status_filter) if status_filter
      scope
    end

    def pending_workflow_scope
      scope = Workflow.where(started_at: nil, state: "queued")
        .where("workflows.created_at > ?", STALE_PENDING_THRESHOLD.ago)
      scope = apply_filters(scope)
      scope = scope.where(job_id: allowed_job_ids) if allowed_job_ids
      scope
    end

    def apply_filters(scope)
      apply_job_filters(scope)
    end

    def apply_job_filters(scope)
      scope = scope.where(job_id: job_id) if job_id
      if repository_id || epic_id || job_type_filter
        scope = scope.joins(:job)
        scope = scope.where(jobs: { repository_id: repository_id }) if repository_id
        scope = scope.where(jobs: { epic_id: epic_id }) if epic_id
        scope = scope.where(jobs: { kind: job_type_kinds }) if job_type_filter
      end
      scope
    end

    def job_type_kinds
      {
        "system" => Job::Kind.infrastructure_values,
        "user" => Job::Kind.user_facing_values
      }.values_at(*job_type_filter).flatten.uniq
    end

    def label_for(workflow)
      job = workflow.job
      "#{job&.slug || "JOB-#{workflow.job_id}"} · #{workflow.trigger_kind}"
    end

    # The issue/PR title behind `label`'s bare slug -- consumers that want a
    # human-readable name (e.g. a hover tooltip) shouldn't have to re-derive
    # it themselves. `Job#title` already falls back to the slug when there's
    # no `issue_title` (cron/direct Jobs), so this is never blank.
    def job_title_for(workflow)
      workflow.job&.title
    end

    def attribution_for(workflow)
      attribution_by_workflow[workflow.id]
    end

    def lane_key_for(attribution)
      if attribution[:worker_storage_key].present? && attribution[:queue_role].present?
        [ "durable", attribution[:worker_storage_key], attribution[:queue_role] ]
      else
        [ "legacy", attribution[:hostname], attribution[:pid] ]
      end
    end

    def lane_payload_key(parts)
      parts.map { |part| part.presence || "unknown" }.join(":")
    end

    def attribution_by_workflow
      @attribution_by_workflow ||= WorkerAttribution.for_workflows(workflows)
    end

    def instance_versions
      @instance_versions ||= instance_version_scope.to_a.select { |instance| expression.nil? || expression.matches_instance?(instance) }
    end

    def instance_version_scope
      scope = InstanceVersion.where(role: "worker")
        .where("started_at < ?", to)
        .where("finished_at IS NULL OR finished_at > ?", from)
      scope = scope.where(hostname: hostname_filter) if hostname_filter
      scope
    end

    def instance_for_hostname(hostname)
      return nil if hostname.blank?

      instance_versions.select { |instance| instance.hostname == hostname }.max_by(&:started_at)
    end

    def instance_payload(instance)
      return nil unless instance

      {
        id: instance.id,
        hostname: instance.hostname,
        started_at: instance.started_at&.iso8601,
        last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
        finished_at: instance.finished_at&.iso8601
      }
    end

    def each_batch(scope, remaining)
      return if remaining <= 0

      scope.find_in_batches(batch_size: [ remaining, 100 ].min) do |batch|
        yield batch
      end
    end

    def capped_count_result(count, limit)
      { count: [ count, limit ].min, count_capped: count > limit }
    end

    def parse_time(value)
      return value if value.respond_to?(:iso8601)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
