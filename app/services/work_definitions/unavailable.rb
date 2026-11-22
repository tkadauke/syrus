module WorkDefinitions
  # Answers for an existing Workflow whose plugin-owned definition cannot be
  # found any more: the plugin was uninstalled, or failed to load in this
  # process. It carries Base's conservative defaults -- operator-only retries,
  # not infrastructure, so cancellation propagates to the Job normally.
  #
  # It can never start work. Its plugin marker is provided by no plugin, so it
  # is never in WorkDefinitions.registry, and WorkDefinitions.for (what every
  # launch path uses) never returns it (formal/SyrusModel/ExistingKindDefinition.lean).
  class Unavailable < Base
    self.kind = "unavailable"
    self.plugin = "__unavailable__"
    self.scope = "job"
  end
end
