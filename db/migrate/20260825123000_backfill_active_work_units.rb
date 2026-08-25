class BackfillActiveWorkUnits < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 100
  ACTIVE_STATES = %w[queued running].freeze
  LANDING_LOCK_KINDS = %w[
    auto_merge
    external_pr_merge
    merge_train
    job_bundle
    landing_validation
    merge_train_validation
    job_bundle_validation
  ].freeze
  CHILD_KINDS = %w[
    landing_validation
    merge_train_validation
    job_bundle_validation
  ].freeze
  SCOPE_BY_KIND = {
    "initial" => "job",
    "pr_comment" => "job",
    "chat_feedback" => "job",
    "ci_failure" => "job",
    "rebase" => "job",
    "stack_rebase" => "epic",
    "auto_merge" => "job",
    "landing_validation" => "job",
    "external_pr_merge" => "job",
    "merge_train" => "epic",
    "job_bundle" => "repository",
    "merge_train_validation" => "epic",
    "job_bundle_validation" => "repository",
    "retry" => "job",
    "checkpoint_resume" => "job",
    "manual_visual_review" => "job",
    "replay" => "job",
    "manual" => "job",
    "resume" => "job",
    "coding_handoff" => "job",
    "local_mode_handoff" => "job",
    "main_grader" => "repository",
    "main_branch_repair" => "repository",
    "manual_agentic_run" => "job",
    "agent_insight" => "repository",
    "external_pr_ingest" => "job",
    "external_pr_feedback" => "job",
    "skill" => "job"
  }.freeze
  START_BLOCK_REASON_MAP = {
    "workflow_admission_budget" => "admission_control",
    "landing start blocked: workflow admission budget" => "admission_control",
    "provider_availability" => "provider_availability",
    "manual_pause" => "manual_pause",
    "main_branch_broken" => "main_branch_health",
    "dependency_failed" => "dependency_failed",
    "stack_dependencies_not_ready" => "stack_dependencies_not_ready",
    "stack_fan_in_base_unavailable" => "stack_fan_in_base_unavailable",
    "urgent_job_active" => "urgent_job_active",
    "epic_wide_workflow_active" => "epic_wide_workflow_active",
    "resource_safety" => "resource_safety"
  }.freeze

  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = "workflows"

    belongs_to :job, class_name: "BackfillActiveWorkUnits::MigrationJob", optional: true
    has_one :work_unit, class_name: "BackfillActiveWorkUnits::MigrationWorkUnit", foreign_key: :workflow_id
  end

  class MigrationJob < ActiveRecord::Base
    self.table_name = "jobs"

    belongs_to :repository, class_name: "BackfillActiveWorkUnits::MigrationRepository", optional: true
  end

  class MigrationRepository < ActiveRecord::Base
    self.table_name = "repositories"
  end

  class MigrationMergeTrain < ActiveRecord::Base
    self.table_name = "merge_trains"

    has_many :members, class_name: "BackfillActiveWorkUnits::MigrationMergeTrainMember", foreign_key: :merge_train_id
  end

  class MigrationMergeTrainMember < ActiveRecord::Base
    self.table_name = "merge_train_members"

    belongs_to :job, class_name: "BackfillActiveWorkUnits::MigrationJob", optional: true
  end

  class MigrationWorkIntent < ActiveRecord::Base
    self.table_name = "work_intents"
  end

  class MigrationWorkUnit < ActiveRecord::Base
    self.table_name = "work_units"
  end

  class MigrationWorkUnitMember < ActiveRecord::Base
    self.table_name = "work_unit_members"
  end

  class MigrationWorkUnitLock < ActiveRecord::Base
    self.table_name = "work_unit_locks"
  end

  def up
    return unless table_exists?(:work_units)
    return unless table_exists?(:work_intents)
    return unless table_exists?(:workflows)

    say_with_time "Backfilling active WorkUnit rows for queued/running workflows" do
      active_workflows_without_units.find_each(batch_size: BATCH_SIZE).count { |workflow| backfill_workflow(workflow) }
    end
  end

  def down
    # Data migration only. WorkUnit rows may have advanced after deploy.
  end

  private

  def active_workflows_without_units
    MigrationWorkflow
      .left_outer_joins(:work_unit)
      .includes(job: :repository)
      .where(state: ACTIVE_STATES, work_units: { id: nil })
      .order(:created_at, :id)
  end

  def backfill_workflow(workflow)
    job = workflow.job
    return false unless job

    kind = work_definition_kind(workflow)
    scope = SCOPE_BY_KIND[kind]
    return false if scope.blank?

    member_jobs = members_for(kind, workflow, job)
    lock_keys = lock_keys_for(kind, job, member_jobs, scope)
    return false if active_lock_conflict?(lock_keys)

    MigrationWorkUnit.transaction do
      intent = find_or_create_intent!(kind, workflow, job, scope)
      unit = create_unit!(kind, workflow, job, scope, intent)
      create_members!(unit, member_jobs)
      create_locks!(unit, lock_keys)
      project_start_block!(unit, workflow)
    end

    true
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def work_definition_kind(workflow)
    artifacts = artifacts_hash(workflow)

    case workflow.trigger_kind
    when "merge_train"
      train_id = artifacts["merge_train_id"]
      return "merge_train" if train_id.blank?

      train = MigrationMergeTrain.find_by(id: train_id)
      train&.epic_id.nil? ? "job_bundle" : "merge_train"
    when "merge_train_validation"
      artifacts["prefetch_landing_unit_kind"] == "job_bundle" ? "job_bundle_validation" : "merge_train_validation"
    else
      workflow.trigger_kind
    end
  end

  def find_or_create_intent!(kind, workflow, job, scope)
    MigrationWorkIntent.find_or_create_by!(idempotency_key: "workflow:#{workflow.id}") do |intent|
      now = Time.current
      ref_metadata = ref_metadata_for(workflow, job)
      scope_type, scope_id = scope_tuple(scope, job)

      intent.kind = kind
      intent.state = "requested"
      intent.repository_id = job.repository_id
      intent.scope_type = scope_type
      intent.scope_id = scope_id
      intent.priority = job.priority
      intent.actor_id = job.user_id
      intent.source_type = "workflow_backfill"
      intent.source_id = workflow.id
      intent.requested_at = workflow.created_at || now
      intent.created_at = now
      intent.updated_at = now
      intent.wait_details = {}
      intent.payload_artifacts = {}
      intent.assign_attributes(ref_metadata)
    end
  end

  def create_unit!(kind, workflow, job, scope, intent)
    now = Time.current
    ref_metadata = ref_metadata_for(workflow, job)
    scope_type, scope_id = scope_tuple(scope, job)

    MigrationWorkUnit.create!(
      work_intent_id: intent.id,
      kind: kind,
      state: workflow.state,
      repository_id: job.repository_id,
      scope_type: scope_type,
      scope_id: scope_id,
      workflow_id: workflow.id,
      parent_work_unit_id: parent_work_unit_id_for(kind, workflow),
      started_at: workflow.started_at,
      finished_at: workflow.finished_at,
      blocked_details: {},
      created_at: now,
      updated_at: now,
      **ref_metadata
    )
  end

  def create_members!(unit, member_jobs)
    now = Time.current

    member_jobs.each_with_index do |member_job, index|
      MigrationWorkUnitMember.create!(
        work_unit_id: unit.id,
        job_id: member_job.id,
        role: index.zero? ? "primary" : "member",
        created_at: now,
        updated_at: now
      )
    end
  end

  def create_locks!(unit, lock_keys)
    now = Time.current

    lock_keys.each do |lock_key|
      attrs = {
        work_unit_id: unit.id,
        lock_key: lock_key,
        acquired_at: now,
        created_at: now,
        updated_at: now
      }
      attrs[:active_lock_key] = lock_key if MigrationWorkUnitLock.column_names.include?("active_lock_key")
      MigrationWorkUnitLock.create!(attrs)
    end
  end

  def project_start_block!(unit, workflow)
    artifacts = artifacts_hash(workflow)
    reason = artifacts["start_blocked_reason"].presence
    return if reason.blank?

    details = artifacts["start_blocked_details"]
    details = {} unless details.is_a?(Hash)

    unit.update!(
      state: "blocked",
      blocked_reason: START_BLOCK_REASON_MAP.fetch(reason.to_s, "preempted"),
      blocked_until: parse_time(artifacts["start_blocked_next_check_at"]),
      blocked_details: details.merge("start_blocked_reason" => reason)
    )
  end

  def active_lock_conflict?(lock_keys)
    return false if lock_keys.empty?

    MigrationWorkUnitLock
      .joins("INNER JOIN work_units ON work_units.id = work_unit_locks.work_unit_id")
      .where(lock_key: lock_keys, released_at: nil, work_units: { state: ACTIVE_STATES })
      .exists?
  end

  def members_for(kind, workflow, job)
    artifacts = artifacts_hash(workflow)

    if kind.in?(%w[merge_train job_bundle])
      train = MigrationMergeTrain.includes(members: :job).find_by(id: artifacts["merge_train_id"])
      jobs = train&.members&.sort_by(&:position)&.filter_map(&:job)
      return jobs if jobs.present?
    end

    if kind.in?(%w[merge_train_validation job_bundle_validation])
      ids = Array(artifacts["prefetch_merge_train_member_job_ids"]).map(&:to_i).select(&:positive?)
      jobs_by_id = MigrationJob.where(id: ids).index_by(&:id)
      jobs = ids.filter_map { |id| jobs_by_id[id] }
      return jobs if jobs.present?
    end

    [ job ]
  end

  def lock_keys_for(kind, job, member_jobs, scope)
    case kind
    when "rebase"
      return [ "maintenance:rebase:job:#{job.id}" ]
    when "stack_rebase"
      keys = member_jobs.map { |member_job| "maintenance:rebase:job:#{member_job.id}" }
      keys << "maintenance:stack_rebase:epic:#{job.epic_id}" if job.epic_id.present?
      return keys.uniq
    end

    keys = member_jobs.map { |member_job| "job:#{member_job.id}" }
    keys << "epic:#{job.epic_id}" if scope == "epic" && job.epic_id.present?
    keys << "repository:#{job.repository_id}" if scope == "repository" && job.repository_id.present?
    keys << "landing:repository:#{job.repository_id}" if LANDING_LOCK_KINDS.include?(kind) && !CHILD_KINDS.include?(kind)
    keys.uniq
  end

  def scope_tuple(scope, job)
    case scope
    when "job"
      [ "job", job.id ]
    when "epic"
      [ "epic", job.epic_id ]
    when "repository"
      [ "repository", job.repository_id ]
    else
      [ scope, job.id ]
    end
  end

  def ref_metadata_for(workflow, job)
    artifacts = artifacts_hash(workflow)
    repository = job.repository

    {
      delivery_track: artifacts["delivery_track"],
      source_repository_id: job.repository_id,
      source_remote_kind: "repository",
      source_ref: artifacts["source_ref"].presence ||
        artifacts["head_ref"].presence ||
        artifacts["branch_name"].presence ||
        job.branch_name,
      target_repository_id: job.repository_id,
      target_remote_kind: "repository",
      target_ref: artifacts["target_ref"].presence ||
        artifacts["base_branch"].presence ||
        repository&.default_branch
    }
  end

  def parent_work_unit_id_for(kind, workflow)
    return nil unless CHILD_KINDS.include?(kind)

    source_workflow_id = artifacts_hash(workflow)["prefetch_source_workflow_id"]
    return nil if source_workflow_id.blank?

    MigrationWorkUnit.find_by(workflow_id: source_workflow_id)&.id
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def artifacts_hash(workflow)
    case workflow.artifacts
    when Hash
      workflow.artifacts
    when String
      JSON.parse(workflow.artifacts.presence || "{}")
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end
end
