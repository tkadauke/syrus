module Coworkers
  class WorkDefinition < ::WorkDefinitions::Base
    self.plugin = "coworkers"
    self.kind = "coworker_run"
    self.workflow_trigger_kind = "coworker_run"
    self.runtime_role = "infrastructure"
    self.scope = "job"
    self.lock_scope = "none"

    def unit_gates
      [ *super, Coworkers::TurnAvailabilityGate ]
    end

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      [ *super, "coworker:#{coworker_id(job)}" ].uniq
    end

    private

    def coworker_id(job)
      raise ArgumentError, "coworker run requires coworkers provenance" unless job.origin == "coworkers" && job.origin_id.present?

      job.origin_id
    end
  end
end
