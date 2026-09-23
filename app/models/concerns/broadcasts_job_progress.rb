module BroadcastsJobProgress
  extend ActiveSupport::Concern

  included do
    after_create_commit :broadcast_job_progress_created
    after_update_commit :broadcast_job_progress_updated, if: :saved_changes_for_job_progress?
  end

  HIGH_CHURN_BROADCAST_INTERVAL = 5.seconds
  HIGH_CHURN_BROADCAST_MAX_KEYS = 10_000
  HIGH_CHURN_BROADCAST_DEADLINES = {}
  HIGH_CHURN_BROADCAST_MUTEX = Mutex.new
  IMMEDIATE_PROGRESS_BROADCAST_COLUMNS = %w[
    state
    started_at
    finished_at
    cleaned_up_at
    failure_count
    head_sha
    run_diagnostic_id
  ].freeze

  private

  def broadcast_job_progress_created
    broadcast_job_progress_event("created", changed: saved_changes.keys)
  end

  def broadcast_job_progress_updated
    return if throttle_high_churn_job_progress_broadcast?

    broadcast_job_progress_event("updated", changed: saved_changes.keys)
  end

  # Column names the frontend entity store is allowed to patch directly from
  # a resource-specific event, keyed by model class. Deliberately a small,
  # curated subset of job_progress_broadcast_columns -- scalar/timestamp
  # fields the JobWorkflow/JobStep/JobRun frontend types already carry, not
  # derived/nested payload (command_spans, health_snapshots, artifacts).
  PROGRESS_PATCH_FIELDS = {
    "Workflow" => %w[state failure_count started_at finished_at cleaned_up_at updated_at],
    "Step" => %w[state started_at finished_at updated_at],
    "Run" => %w[
      state started_at finished_at last_heartbeat_at updated_at
      agent_outcome agent_turns agent_pr_title agent_summary
      cost_usd input_tokens output_tokens
    ]
  }.freeze

  def broadcast_job_progress_event(action, changed:)
    owner_job = job_for_progress_broadcast
    return unless owner_job&.user

    AppEvents.broadcast(
      user: owner_job.user,
      type: "job.updated",
      resource: "job",
      id: owner_job.id,
      changed: [ "#{self.class.name.underscore}.#{action}", *changed.map(&:to_s) ].uniq,
      revision: owner_job.entity_revision
    )

    # A second, resource-specific event alongside the job-level rollup above:
    # the job-level event is what drives the existing job-detail
    # invalidation/refetch path, while this one carries enough of a diff for
    # the frontend entity store to patch the Workflow/Step/Run record
    # directly (see app/frontend/lib/appEvents.ts) without waiting on that
    # refetch. Workflow/Step/Run churn frequently while a Job is running, so
    # this one is job-scoped (JobChannel) rather than broadcast to the
    # owner's global channel -- every other tab that owner has open, showing
    # anything other than this specific Job, would otherwise receive it too.
    AppEvents.broadcast_job_resource(
      job_id: owner_job.id,
      type: "#{self.class.name.underscore}.#{action}",
      resource: self.class.name.underscore,
      id: id,
      changed: changed.map(&:to_s),
      revision: entity_revision,
      payload: { fields: job_progress_patch_fields }
    )

    chat_session_ids_for(owner_job).each do |session_id|
      AppEvents.broadcast(
        user: owner_job.user,
        type: "chat.updated",
        resource: "chat",
        id: session_id,
        payload: { action: "job_status_changed", job_id: owner_job.id }
      )
    end
  end

  def job_progress_patch_fields
    PROGRESS_PATCH_FIELDS.fetch(self.class.name, %w[state updated_at]).index_with { |field| progress_patch_value(field) }
  end

  def progress_patch_value(field)
    value = public_send(field)
    case value
    when Time, ActiveSupport::TimeWithZone then value.iso8601(3)
    when BigDecimal then value.to_f
    else value
    end
  end

  def chat_session_ids_for(job)
    session_ids = ChatProposal.confirmed.where(job: job).distinct.pluck(:chat_session_id)
    session_ids << job.linked_chat_id if job.linked_chat_id.present?
    session_ids.uniq
  end

  def saved_changes_for_job_progress?
    (saved_changes.keys & job_progress_broadcast_columns).any?
  end

  def throttle_high_churn_job_progress_broadcast?
    return false if (saved_changes.keys & IMMEDIATE_PROGRESS_BROADCAST_COLUMNS).any?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cache_key = [
      "job_progress_broadcast",
      self.class.name,
      id
    ].join(":")

    HIGH_CHURN_BROADCAST_MUTEX.synchronize do
      deadline = HIGH_CHURN_BROADCAST_DEADLINES[cache_key]
      return true if deadline && deadline > now

      if HIGH_CHURN_BROADCAST_DEADLINES.size >= HIGH_CHURN_BROADCAST_MAX_KEYS
        HIGH_CHURN_BROADCAST_DEADLINES.delete_if { |_key, expires_at| expires_at <= now }
        HIGH_CHURN_BROADCAST_DEADLINES.shift if HIGH_CHURN_BROADCAST_DEADLINES.size >= HIGH_CHURN_BROADCAST_MAX_KEYS
      end

      HIGH_CHURN_BROADCAST_DEADLINES[cache_key] = now + HIGH_CHURN_BROADCAST_INTERVAL.to_f
      false
    end
  end

  def job_progress_broadcast_columns
    %w[
      state
      started_at
      finished_at
      cleaned_up_at
      failure_count
      artifacts
      details
      agent_outcome
      agent_turns
      agent_pr_title
      agent_summary
      parent_session_id
      head_sha
      cost_usd
      input_tokens
      output_tokens
      cache_creation_input_tokens
      cache_read_input_tokens
      run_diagnostic_id
    ]
  end
end
