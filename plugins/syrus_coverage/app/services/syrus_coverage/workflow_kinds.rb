module SyrusCoverage
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.step_kinds
      [
        {
          kind: "coverage_analyze", handler: "SyrusCoverage::AnalyzeStep",
          label: "Analyze coverage", style: "bg-yellow-100 text-yellow-700", agentic: false,
          repair_semantics: :deterministic_idempotent
        },
        {
          kind: "coverage_pr_comment", handler: "SyrusCoverage::PrCommentStep",
          label: "Post coverage comment", style: "bg-yellow-100 text-yellow-700", agentic: false,
          fail_policy: :advance,
          repair_semantics: :publication
        }
      ]
    end
  end
end
