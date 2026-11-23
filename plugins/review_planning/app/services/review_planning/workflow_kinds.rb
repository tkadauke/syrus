module ReviewPlanning
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.step_kinds
      [
        {
          kind: "review_plan", handler: "ReviewPlanning::LegacyStep",
          label: "Review plan (retired)", style: "bg-gray-100 text-gray-700", agentic: false,
          fail_policy: :advance,
          repair_semantics: :deterministic_idempotent
        }
      ]
    end
  end
end
