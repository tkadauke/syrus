module Coworkers
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.trigger_kinds
      [ {
        kind: "coworker_run", template: "Coworkers::Workflow",
        label: "Coworker run", style: "bg-violet-100 text-violet-700",
        retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
        owns_job_lifecycle: true
      } ]
    end

    def self.step_kinds
      [
        {
          kind: "coworker_run", handler: "Coworkers::RunStep",
          label: "Coworker run", style: "bg-violet-100 text-violet-700",
          agentic: true, agent_role: AgentRole::COWORKER
        },
        {
          kind: "post_to_chat", handler: "Coworkers::PostToChat",
          label: "Post to chat", style: "bg-violet-100 text-violet-700",
          agentic: false
        }
      ]
    end

    def self.job_kinds
      [ { kind: "coworker_task", infrastructure: true, issueless: true } ]
    end

    def self.work_definitions
      [ Coworkers::WorkDefinition ]
    end
  end
end
