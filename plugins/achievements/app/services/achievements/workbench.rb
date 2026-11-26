module Achievements
  # The development workbench's availability and catalog. It is owned entirely
  # by this plugin: it is offered only while Achievements AND the syrus_dev
  # plugin are effectively enabled, and syrus_dev neither knows about nor hosts
  # it. The other plugin is identified by name through the host's plugin
  # registry, never by reaching into its code.
  module Workbench
    REQUIRED_PLUGIN = "syrus_dev".freeze
    PAGE_PATH = "/admin/achievements_workbench".freeze

    # Implementation status of a definition: whether the runtime can actually
    # award it today. `planned` definitions exist in the registry only.
    STATUSES = %w[implemented partial planned].freeze

    def self.available?
      Achievements.enabled? && plugin_effectively_enabled?(REQUIRED_PLUGIN)
    end

    def self.plugin_effectively_enabled?(name)
      manifest = Syrus::Host::PluginRegistry.all_plugins.find { |candidate| candidate.name == name }
      !!(manifest&.enabled? && Syrus::Host::PluginRegistry.health.healthy?(name))
    end

    def self.implementation_status(definition)
      evaluator = definition.evaluator.safe_constantize
      evaluator_ready = evaluator.is_a?(Class) && evaluator <= Achievements::Evaluators::Base
      trigger_ready = Achievements::EventAdapters.event_names.include?(definition.trigger)
      return "implemented" if evaluator_ready && trigger_ready

      evaluator_ready || trigger_ready ? "partial" : "planned"
    end

    def self.definition_json(definition)
      {
        key: definition.key,
        version: definition.version,
        scope: definition.scope,
        trigger: definition.trigger,
        evaluator: definition.evaluator,
        subject_kinds: definition.subject_kinds,
        visibility: definition.visibility,
        category: definition.category,
        rarity: definition.rarity,
        presentation: definition.presentation,
        implementation_status: implementation_status(definition)
      }
    end

    # Every registered definition, hidden ones included: this is an admin
    # development surface working with synthetic fixtures, not user data.
    def self.catalog(registry: Achievements::Registry.default)
      {
        definitions: registry.definitions.map { |definition| definition_json(definition) },
        problems: registry.problems,
        vocabulary: {
          scope: Achievements::Registry::SCOPES,
          category: Achievements::Registry::CATEGORIES,
          rarity: Achievements::Registry::RARITIES,
          visibility: Achievements::Registry::VISIBILITIES,
          implementation_status: STATUSES,
          trigger: registry.definitions.map(&:trigger).uniq.sort
        }
      }
    end
  end
end
