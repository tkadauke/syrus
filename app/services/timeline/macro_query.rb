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
  # WorkUnit/admission-block lookup.
  class MacroQuery
    DEFAULT_WINDOW = 1.hour

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(from: nil, to: nil, repository_id: nil, epic_id: nil, job_id: nil, hostname: nil, status: nil)
      @to = parse_time(to) || Time.current
      @from = parse_time(from) || (@to - DEFAULT_WINDOW)
      @repository_id = repository_id.presence
      @epic_id = epic_id.presence
      @job_id = job_id.presence
      @hostname_filter = hostname.presence
      @status_filter = Array(status).flat_map { |value| value.to_s.split(",") }.compact_blank.presence
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

    private

    attr_reader :from, :to, :repository_id, :epic_id, :job_id, :hostname_filter, :status_filter

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
      pending_workflows.map do |workflow|
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
      @workflows ||= begin
        scope = Workflow.where.not(started_at: nil)
          .where("workflows.started_at < ?", to)
          .where("workflows.finished_at IS NULL OR workflows.finished_at > ?", from)
          .includes(:job, :work_unit)
          .order(:started_at)
        scope = apply_job_filters(scope)
        scope = scope.where(state: status_filter) if status_filter
        scope.to_a
      end
    end

    def pending_workflows
      @pending_workflows ||= begin
        scope = Workflow.where(started_at: nil, state: "queued").includes(:job, :work_unit).order(:created_at)
        apply_job_filters(scope).to_a
      end
    end

    def apply_job_filters(scope)
      scope = scope.where(job_id: job_id) if job_id
      if repository_id || epic_id
        scope = scope.joins(:job)
        scope = scope.where(jobs: { repository_id: repository_id }) if repository_id
        scope = scope.where(jobs: { epic_id: epic_id }) if epic_id
      end
      scope
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
      @instance_versions ||= begin
        scope = InstanceVersion.where(role: "worker")
          .where("started_at < ?", to)
          .where("finished_at IS NULL OR finished_at > ?", from)
        scope = scope.where(hostname: hostname_filter) if hostname_filter
        scope.to_a
      end
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

    def parse_time(value)
      return value if value.respond_to?(:iso8601)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
