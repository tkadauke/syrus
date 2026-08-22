require "set"

module WorkUnits
  class Ownership
    ACTIVE_STATES = %w[queued blocked running].freeze

    def self.active_for_job?(job)
      active_job_ids([ job.id ]).include?(job.id)
    end

    def self.active_job_ids(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return Set.new if ids.empty?

      active_units_by_job_id(ids).keys.to_set |
        legacy_active_workflow_job_ids(ids).to_set
    end

    def self.active_trigger_kinds_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      units = active_units_by_job_id(ids)
      result = units.transform_values { |unit| unit.workflow&.trigger_kind || unit.kind }
      remaining_ids = ids - result.keys
      result.merge(legacy_active_workflow_trigger_kinds_by_job_id(remaining_ids))
    end

    def self.active_units_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      WorkUnitMember
        .joins(:work_unit)
        .includes(work_unit: :workflow)
        .where(job_id: ids, work_units: { state: ACTIVE_STATES })
        .order(Arel.sql("work_units.created_at DESC, work_units.id DESC"))
        .each_with_object({}) do |member, result|
          result[member.job_id] ||= member.work_unit
        end
    end

    def self.legacy_active_workflow_job_ids(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return [] if ids.empty?

      Workflow.active.where(job_id: ids).distinct.pluck(:job_id)
    end

    def self.legacy_active_workflow_trigger_kinds_by_job_id(job_ids)
      ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return {} if ids.empty?

      Workflow
        .where(job_id: ids, state: ACTIVE_STATES)
        .select(:job_id, :trigger_kind, :created_at, :id)
        .order(:job_id, created_at: :desc, id: :desc)
        .each_with_object({}) do |workflow, result|
          result[workflow.job_id] ||= workflow.trigger_kind
        end
    end
  end
end
