require "set"

module WorkUnits
  class Ownership
    ACTIVE_STATES = %w[queued blocked running].freeze
    RUNNABLE_STATES = %w[queued running].freeze
    LANDING_OWNED_KINDS = %w[
      auto_merge
      external_pr_merge
      landing_validation
      merge_train
      merge_train_validation
      stack_rebase
    ].freeze
    def self.active_for_job?(job)
      active_job_ids([ job.id ]).include?(job.id)
    end

    def self.active_for_job_kind?(job, kinds)
      active_job_ids([ job.id ], kinds: kinds).include?(job.id)
    end

    def self.active_for_epic?(epic, kinds: nil)
      return false unless epic

      active_units_for_epic(epic, kinds: kinds).any? || legacy_active_epic_workflows(epic, kinds: kinds).exists?
    end

    def self.active_for_lock_key?(lock_key, kinds: nil)
      active_unit_for_lock_key(lock_key, kinds: kinds).present?
    end

    def self.active_ci_failure_blocking_unit_for_job(job)
      active_units_for_job(job).find { |unit| unit.definition.blocks_ci_failure? }
    end

    def self.ci_failure_blocked_for_job?(job)
      active_ci_failure_blocking_unit_for_job(job).present?
    end

    def self.active_unit_for_lock_key(lock_key, kinds: nil)
      key = lock_key.to_s
      return nil if key.blank?

      scope = WorkUnit
        .joins(:work_unit_locks)
        .where(state: ACTIVE_STATES, work_unit_locks: { lock_key: key, released_at: nil })
        .includes(:workflow)
      scope = scope.where(kind: Array(kinds).map(&:to_s)) if kinds.present?
      scope.order(created_at: :desc, id: :desc).first
    end

    def self.active_job_ids(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return Set.new if ids.empty?

      active_units_by_job_id(ids, kinds: kinds).keys.to_set |
        legacy_active_workflow_job_ids(ids, kinds: kinds).to_set
    end

    def self.all_active_job_ids(kinds: nil)
      all_active_unit_job_ids(kinds: kinds).to_set |
        legacy_active_workflow_job_ids(nil, kinds: kinds).to_set
    end

    def self.runnable_job_ids(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return Set.new if ids.empty?

      runnable_unit_job_ids(ids, kinds: kinds).to_set |
        legacy_active_workflow_job_ids(ids, kinds: kinds).to_set
    end

    def self.all_runnable_job_ids(kinds: nil)
      runnable_unit_job_ids(nil, kinds: kinds).to_set |
        legacy_active_workflow_job_ids(nil, kinds: kinds).to_set
    end

    def self.active_workflow_ids(job_ids = nil, kinds: nil, agent_provider: nil, states: ACTIVE_STATES)
      unit_workflow_ids(job_ids, kinds: kinds, agent_provider: agent_provider, states: states).to_set |
        legacy_active_workflow_ids(job_ids, kinds: kinds, agent_provider: agent_provider, states: states).to_set
    end

    def self.active_workflow_count(job_ids = nil, kinds: nil, agent_provider: nil, states: ACTIVE_STATES)
      active_workflow_ids(job_ids, kinds: kinds, agent_provider: agent_provider, states: states).size
    end

    def self.active_trigger_kinds_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      units = active_units_by_job_id(ids)
      result = units.transform_values { |unit| unit.workflow&.trigger_kind || unit.kind }
      remaining_ids = ids - result.keys
      result.merge(legacy_active_workflow_trigger_kinds_by_job_id(remaining_ids))
    end

    def self.active_trigger_kind_lists_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      result = Hash.new { |hash, key| hash[key] = [] }
      WorkUnitMember
        .joins(:work_unit)
        .left_outer_joins(work_unit: :workflow)
        .where(job_id: ids, work_units: { state: ACTIVE_STATES })
        .pluck("work_unit_members.job_id", "work_units.kind", "workflows.trigger_kind")
        .each do |job_id, unit_kind, workflow_trigger_kind|
          result[job_id] << (workflow_trigger_kind.presence || unit_kind)
        end

      legacy_active_workflows_scope(ids)
        .pluck(:job_id, :trigger_kind)
        .each do |job_id, trigger_kind|
          result[job_id] << trigger_kind
        end

      result.transform_values { |trigger_kinds| trigger_kinds.compact.map(&:to_s).uniq }
    end

    def self.active_units_by_job_id(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      active_unit_members_for_job_ids(ids, kinds: kinds)
        .order(Arel.sql("work_units.created_at DESC, work_units.id DESC"))
        .each_with_object({}) do |member, result|
          result[member.job_id] ||= member.work_unit
        end
    end

    def self.active_units_for_job(job, kinds: nil)
      return [] unless job

      active_unit_members_for_job_ids([ job.id ], kinds: kinds)
        .order(Arel.sql("work_units.created_at DESC, work_units.id DESC"))
        .map(&:work_unit)
        .uniq
    end

    def self.blocked_for_job?(job, kinds: nil, include_landing: false)
      return false unless job

      blocked_job_ids([ job&.id ], kinds: kinds, include_landing: include_landing).include?(job.id)
    end

    def self.blocked_job_ids(job_ids, kinds: nil, include_landing: false)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return Set.new if ids.empty?

      blocked_unit_job_ids_scope(kinds: kinds, include_landing: include_landing)
        .where(job_id: ids)
        .distinct
        .pluck(:job_id)
        .to_set
    end

    def self.all_blocked_job_ids(kinds: nil, include_landing: false)
      blocked_unit_job_ids_scope(kinds: kinds, include_landing: include_landing)
        .distinct
        .pluck(:job_id)
        .to_set
    end

    def self.blocked_data_by_job_id(job_ids, kinds: nil, include_landing: false)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      blocked_unit_job_ids_scope(kinds: kinds, include_landing: include_landing)
        .where(job_id: ids)
        .includes(:work_unit)
        .order(Arel.sql("work_units.updated_at DESC, work_units.id DESC"))
        .each_with_object({}) do |member, result|
          next if result.key?(member.job_id)

          unit = member.work_unit
          reason = unit.blocked_reason.presence
          next unless reason

          result[member.job_id] = {
            reason: reason,
            at: unit.updated_at&.iso8601,
            next_check_at: unit.blocked_until&.iso8601,
            count: nil,
            details: unit.blocked_details.presence
          }
        end
    end

    def self.blocked_unit_job_ids_scope(kinds: nil, include_landing: false)
      scope = WorkUnitMember.joins(:work_unit).where(work_units: { state: "blocked" })
      scope = scope.where(work_units: { kind: Array(kinds).map(&:to_s) }) if kinds.present?
      scope = scope.where.not(work_units: { kind: WorkDefinitions.landing_lock_kinds }) unless include_landing
      scope
    end

    def self.active_unit_members_for_job_ids(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return WorkUnitMember.none if ids.empty?

      scope = WorkUnitMember
        .joins(:work_unit)
        .includes(work_unit: :workflow)
        .where(job_id: ids, work_units: { state: ACTIVE_STATES })
      scope = scope.where(work_units: { kind: Array(kinds).map(&:to_s) }) if kinds.present?
      scope
    end

    def self.active_units_for_epic(epic, kinds: nil)
      return [] unless epic

      scope = WorkUnit
        .where(state: ACTIVE_STATES, scope_type: "epic", scope_id: epic.id)
        .includes(:workflow)
      scope = scope.where(kind: Array(kinds).map(&:to_s)) if kinds.present?
      scope.order(:created_at, :id).to_a
    end

    def self.legacy_active_epic_workflows(epic, kinds: nil)
      return Workflow.none unless epic

      scope = Workflow.active.where(job_id: epic.jobs.select(:id))
      legacy_active_workflows_scope(nil, kinds: kinds, base_scope: scope)
    end

    def self.legacy_active_workflow_job_ids(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      legacy_active_workflows_scope(ids, kinds: kinds).distinct.pluck(:job_id)
    end

    def self.all_active_unit_job_ids(kinds: nil)
      scope = WorkUnitMember.joins(:work_unit).where(work_units: { state: ACTIVE_STATES })
      scope = scope.where(work_units: { kind: Array(kinds).map(&:to_s) }) if kinds.present?
      scope.distinct.pluck(:job_id)
    end

    def self.runnable_unit_job_ids(job_ids, kinds: nil)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      scope = WorkUnitMember.joins(:work_unit).where(work_units: { state: RUNNABLE_STATES })
      scope = scope.where(job_id: ids) if ids.any?
      scope = scope.where(work_units: { kind: Array(kinds).map(&:to_s) }) if kinds.present?
      scope.distinct.pluck(:job_id)
    end

    def self.unit_workflow_ids(job_ids = nil, kinds: nil, agent_provider: nil, states: ACTIVE_STATES)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      scope = WorkUnit.joins(:workflow).where(state: Array(states).map(&:to_s))
      scope = scope.joins(:work_unit_members).where(work_unit_members: { job_id: ids }) if ids.any?
      scope = scope.where(kind: Array(kinds).map(&:to_s)) if kinds.present?
      scope = scope.where(workflows: { agent_provider: agent_provider.to_s }) if agent_provider.present?
      scope.distinct.pluck(:workflow_id)
    end

    def self.legacy_active_workflow_ids(job_ids = nil, kinds: nil, agent_provider: nil, states: ACTIVE_STATES)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      workflow_states = Array(states).map(&:to_s) & %w[queued running]
      return [] if workflow_states.empty?

      scope = legacy_active_workflows_scope(ids, kinds: kinds, base_scope: Workflow.where(state: workflow_states))
      scope = scope.where(agent_provider: agent_provider.to_s) if agent_provider.present?
      scope.distinct.pluck(:id)
    end

    def self.legacy_active_workflow_trigger_kinds_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      legacy_active_workflows_scope(ids)
        .select(:job_id, :trigger_kind, :created_at, :id)
        .order(:job_id, created_at: :desc, id: :desc)
        .each_with_object({}) do |workflow, result|
          result[workflow.job_id] ||= workflow.trigger_kind
        end
    end

    def self.legacy_active_workflows_scope(job_ids = nil, kinds: nil, base_scope: Workflow.active)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      requested_kinds = Array(kinds).map(&:to_s).presence
      visible_kinds = legacy_visible_trigger_kinds(requested_kinds)
      return Workflow.none if visible_kinds.empty?

      scope = base_scope
      scope = scope.where(job_id: ids) if ids.any?
      scope.where(trigger_kind: visible_kinds)
    end

    def self.legacy_visible_trigger_kinds(kinds = nil)
      requested = Array(kinds).map(&:to_s).presence || Workflow::TriggerKind.values
      requested.select { |kind| legacy_fallback_visible_for_trigger_kind?(kind) }.uniq
    end

    def self.legacy_fallback_visible_for_trigger_kind?(kind)
      kind = kind.to_s
      return true if kind == "replay"
      return false unless Workflow::TriggerKind.values.include?(kind)
      return !WorkUnits::PathOwnership.work_unit_owned?("landing_queue") if LANDING_OWNED_KINDS.include?(kind)

      !WorkUnits::PathOwnership.work_unit_owned?("retry")
    end
  end
end
