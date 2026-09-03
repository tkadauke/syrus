module Syrus
  module Plugin
    # Marker interface for plugins that own a workflow.
    #
    # Workflow::TriggerKind::ENTRIES and Step::Kind::ENTRIES were frozen array
    # literals in core, so a plugin could not describe its own workflow at all:
    # a subsystem with its own trigger kind and step handlers had to be core by
    # construction, whatever else it was.
    #
    # Providers return entry attribute hashes, in the same shape the built-in
    # literals use:
    #
    #   def self.trigger_kinds
    #     [ { kind: "agent_insight", template: "AgentInsight", label: "Agent insight",
    #         style: "bg-amber-100 text-amber-700", runtime_role: "infrastructure" } ]
    #   end
    #
    #   def self.step_kinds
    #     [ { kind: "agent_insight_run", handler: "AgentInsightRun",
    #         label: "Agent insight", style: "...", agentic: true } ]
    #   end
    #
    # Both default to [], so a provider may contribute only one of them. A
    # plugin may not redefine a built-in kind: core keeps its own, and the
    # collision is logged rather than silently winning either way.
    # Both methods are optional: a provider may contribute only trigger kinds,
    # or only step kinds. A plugin may not redefine a built-in kind -- core
    # keeps its own, and the collision is logged rather than silently winning
    # either way, since load-order-dependent workflow behavior is worse than a
    # rejected registration.
    module WorkflowKinds
    end
  end
end
