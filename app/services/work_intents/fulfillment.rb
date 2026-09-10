module WorkIntents
  module Fulfillment
    IMPLEMENTATION_TRIGGER_KINDS = %w[
      initial
      retry
      coding_handoff
      local_mode_handoff
      skill
    ].freeze

    module_function

    def already_fulfilled?(intent)
      fulfilled_job_initial_intent?(intent)
    end

    def fulfill_if_already_satisfied!(intent)
      return false unless intent&.requested? || intent&.waiting?
      return false unless already_fulfilled?(intent)

      intent.satisfy!
      true
    end

    def fulfilled_job_initial_intent?(intent)
      return false unless intent&.kind == "initial"
      return false unless intent.scope_type == "job" && intent.scope_id.present?

      job = Job.find_by(id: intent.scope_id)
      return false unless job&.implemented? || job&.approved? || job&.landing? || job&.closed?

      latest_unit_created_at = intent.work_units.maximum(:created_at) || intent.created_at || intent.requested_at
      fulfilled_by_later_workflow?(intent, job, latest_unit_created_at)
    end

    def fulfilled_by_later_workflow?(intent, job, latest_unit_created_at)
      scope = job.workflows
        .where(state: "succeeded", trigger_kind: IMPLEMENTATION_TRIGGER_KINDS)
      scope = scope.where("created_at > ?", latest_unit_created_at) if latest_unit_created_at
      scope = scope.where.not(id: intent.work_units.where.not(workflow_id: nil).select(:workflow_id))
      scope.exists?
    end
  end
end
