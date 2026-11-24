module MainBranchHealth
  # The `main_grader` (health observation) and `main_branch_repair` (repair)
  # workflows, and the `main_grader` Job kind. The repair Job is a `direct` Job
  # tagged with a system kind, so it needs no Job kind of its own.
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.trigger_kinds
      [
        {
          kind: "main_grader", template: "MainGrader", label: "Main branch grader",
          style: "bg-gray-100 text-gray-500", retry_label: nil, feedback_kind: nil,
          runtime_role: "infrastructure", owns_job_lifecycle: true
        },
        {
          kind: "main_branch_repair", template: "MainBranchRepair", label: "Main branch repair",
          style: "bg-red-100 text-red-800", retry_label: "Retry failed step", feedback_kind: nil,
          runtime_role: "first_class", owns_job_lifecycle: true, escalation_urgency: "urgent"
        }
      ]
    end

    def self.job_kinds
      [ { kind: "main_grader", infrastructure: true, issueless: true } ]
    end

    def self.work_definitions
      [ MainBranchHealth::GraderWorkDefinition, MainBranchHealth::RepairWorkDefinition ]
    end
  end
end
