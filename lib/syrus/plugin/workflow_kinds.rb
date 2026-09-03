module Syrus
  module Plugin
    # Marker interface for plugins that own a workflow.
    #
    # Workflow::TriggerKind::ENTRIES, Step::Kind::ENTRIES and Job::KINDS were
    # frozen array literals in core, so a plugin could not describe its own
    # workflow at all: a subsystem with its own trigger kind, step handlers,
    # and Job kind had to be core by construction, whatever else it was.
    #
    # Providers return entry attribute hashes, in the same shape the built-in
    # literals use:
    #
    #   def self.trigger_kinds
    #     [ { kind: "agent_insight", template: "AgentInsights::Workflow",
    #         label: "Agent insight", style: "bg-amber-100 text-amber-700",
    #         runtime_role: "infrastructure" } ]
    #   end
    #
    #   def self.step_kinds
    #     [ { kind: "agent_insight_run", handler: "AgentInsights::RunStep",
    #         label: "Agent insight", style: "...", agentic: true,
    #         agent_role: AgentRole::AGENT_INSIGHT } ]
    #   end
    #
    #   def self.job_kinds
    #     [ { kind: "agent_insight", infrastructure: true, issueless: true } ]
    #   end
    #
    # A workflow also needs a WorkDefinition -- the retry/lock/landing policy
    # WorkUnits::Launcher reads. Plugin-owned definitions subclass
    # WorkDefinitions::Base, set `self.plugin` to the plugin name, and are
    # named here so WorkDefinitions.registry both loads them and drops them
    # again when the plugin is disabled:
    #
    #   def self.work_definitions
    #     [ AgentInsights::WorkDefinition ]
    #   end
    #
    # Every method is optional and defaults to []: a provider may contribute
    # only trigger kinds, or only step kinds, or only a Job kind. A plugin may
    # not redefine a built-in kind -- core keeps its own, and the collision is
    # logged rather than silently winning either way, since load-order-dependent
    # workflow behavior is worse than a rejected registration.
    module WorkflowKinds
    end
  end
end
