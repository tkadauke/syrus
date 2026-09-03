module App
  # Resolves plugin-contributed panels for one named slot on a core page.
  #
  # Mirrors Repositories::PluginRepoTabsPayload: visibility is per record, so
  # providers are asked with the host page's context rather than answering
  # once instance-wide.
  class UiSlotsPayload
    def self.panels_for(slot:, context: {})
      unless Syrus::Plugin::UiSlot.valid_slot?(slot)
        raise ArgumentError, "Unknown UI slot: #{slot.inspect}. Valid: #{Syrus::Plugin::UiSlot::SLOTS.inspect}"
      end

      Syrus::PluginRegistry.providers_for(:ui_slot)
        .flat_map { |provider| panels_from_provider(provider, slot: slot, context: context) }
        .each_with_index.sort_by { |panel, index| [ panel[:order].to_i, index ] }
        .map(&:first)
    end

    def self.panels_from_provider(provider, slot:, context:)
      PerformanceLogging.plugin_call(extension_point: :ui_slot, provider: provider, operation: :ui_slots) do
        Array(provider.ui_slots(slot: slot, context: context)).map { |panel| panel_payload(panel) }
      end
    end

    # `props` lets a provider ship the data its panel needs. Without it, core
    # would have to compute plugin-shaped payload for a plugin-owned component,
    # which is the coupling the slot exists to remove.
    def self.panel_payload(panel)
      panel = panel.to_h.symbolize_keys
      {
        id: panel.fetch(:id).to_s,
        component: panel.fetch(:component).to_s,
        order: panel[:order].to_i,
        props: panel[:props].presence&.as_json,
        key: panel[:key].presence&.to_s,
        label: panel[:label].presence&.to_s,
        label_key: panel[:label_key].presence&.to_s
      }.compact
    end

    def initialize(slot:, context: {})
      @slot = slot
      @context = context
    end

    def as_json(*)
      { panels: self.class.panels_for(slot: @slot, context: @context) }
    end
  end
end
