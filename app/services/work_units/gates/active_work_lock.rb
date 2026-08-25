module WorkUnits
  module Gates
    class ActiveWorkLock
      REASON = "active_work_lock"
      RETRY_DELAY = 1.minute

      def self.call(work_unit, **) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        conflict = lock_keys.filter_map do |lock_key|
          owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
          next if owner.blank? || same_runtime_lock_owner?(owner)

          { "lock_key" => lock_key, "work_unit_id" => owner.id, "workflow_id" => owner.workflow_id }
        end.first
        return GateResult.pass unless conflict

        GateResult.block(
          reason: REASON,
          retry_at: RETRY_DELAY.from_now,
          details: conflict
        )
      end

      private

      attr_reader :work_unit

      def lock_keys
        return [] unless work_unit.definition.lock_conflicts_enforced?
        return [] unless primary_job

        work_unit.definition.lock_keys_for(
          job: primary_job,
          member_jobs: member_jobs,
          artifacts: work_unit.workflow&.artifacts.to_h
        )
      end

      def primary_job
        @primary_job ||= member_jobs.first || work_unit.workflow&.job || Job.find_by(id: work_unit.scope_id)
      end

      def member_jobs
        @member_jobs ||= work_unit.work_unit_members.includes(:job).order(:id).filter_map(&:job)
      end

      def same_runtime_lock_owner?(owner)
        return true if owner.id.to_i == work_unit.id.to_i

        owner.workflow_id.present? &&
          work_unit.workflow_id.present? &&
          owner.workflow_id.to_i == work_unit.workflow_id.to_i
      end
    end
  end
end
