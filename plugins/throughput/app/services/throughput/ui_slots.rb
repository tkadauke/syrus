module Throughput
  class UiSlots
    include Syrus::Plugin::UiSlot

    def self.ui_slots(slot:, context:)
      return [] unless slot == "repository.detail"
      return [] if context[:repository].blank?

      [ { id: "throughput.panel", component: "throughput/ThroughputPanel", order: 20 } ]
    end
  end
end
