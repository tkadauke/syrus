module WorkUnitsSpecHelpers
  def attach_work_unit(workflow, state: workflow.state, blocked_reason: nil, blocked_details: nil, blocked_until: nil, member_jobs: nil, kind: nil, job: nil)
    job ||= workflow.job
    raise ArgumentError, "workflow must have a job" unless job

    definition = WorkDefinitions.for(kind || work_unit_definition_kind_for(workflow))
    artifacts = workflow.artifacts.to_h
    members = Array(member_jobs).presence || definition.members_for(job: job, artifacts: artifacts)
    scope = definition.scope_for(job: job, artifacts: artifacts)
    ref_metadata = definition.ref_metadata_for(job: job, artifacts: artifacts)

    WorkUnit.transaction do
      unit = workflow.work_unit || WorkUnit.create!(
        work_intent: WorkIntent.create!(
          kind: definition.kind,
          state: "requested",
          repository: job.repository,
          scope_type: scope.type,
          scope_id: scope.id,
          actor: job.user,
          source_type: "spec",
          source_id: workflow.id,
          payload_artifacts: artifacts,
          **ref_metadata.attributes
        ),
        kind: definition.kind,
        state: state,
        repository: job.repository,
        scope_type: scope.type,
        scope_id: scope.id,
        workflow: workflow,
        started_at: workflow.started_at,
        finished_at: workflow.finished_at,
        **ref_metadata.attributes
      )

      unit.work_intent.update!(
        kind: definition.kind,
        repository: job.repository,
        scope_type: scope.type,
        scope_id: scope.id,
        payload_artifacts: artifacts,
        **ref_metadata.attributes
      )
      unit.update!(
        kind: definition.kind,
        state: state,
        repository: job.repository,
        scope_type: scope.type,
        scope_id: scope.id,
        blocked_reason: blocked_reason,
        blocked_details: blocked_details || {},
        blocked_until: blocked_until,
        **ref_metadata.attributes
      )

      member_ids = members.map(&:id)
      unit.work_unit_members.where.not(job_id: member_ids).destroy_all
      members.each_with_index do |member_job, index|
        role = index.zero? ? "primary" : "member"
        member = unit.work_unit_members.find_or_initialize_by(job: member_job)
        member.role = role
        member.save!
      end

      lock_keys = definition.lock_keys_for(job: job, member_jobs: members, artifacts: artifacts)
      unit.work_unit_locks.active.where.not(lock_key: lock_keys).find_each(&:release!)
      lock_keys.each do |lock_key|
        WorkUnitLock.active.where(lock_key: lock_key).where.not(work_unit_id: unit.id).find_each(&:release!)
        unit.work_unit_locks.find_or_create_by!(lock_key: lock_key)
      end

      unit
    end
  end

  private

  def work_unit_definition_kind_for(workflow)
    case workflow.trigger_kind
    when "merge_train"
      epicless_merge_train_workflow?(workflow) ? "job_bundle" : "merge_train"
    when "merge_train_validation"
      workflow.artifacts.to_h["prefetch_landing_unit_kind"] == "job_bundle" ? "job_bundle_validation" : "merge_train_validation"
    else
      workflow.trigger_kind
    end
  end

  def epicless_merge_train_workflow?(workflow)
    train_id = workflow.artifacts.to_h["merge_train_id"]
    return false if train_id.blank?

    MergeTrain.where(id: train_id, epic_id: nil).exists?
  end
end

RSpec.configure do |config|
  config.include WorkUnitsSpecHelpers
end
