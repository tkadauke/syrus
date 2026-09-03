module Throughput
  class UiSlots
    include Syrus::Plugin::UiSlot

    # Hidden in simple mode for the same reason the panel always was: the
    # numbers are for someone tuning a delivery pipeline, not for a
    # non-technical operator watching a feature land.
    def self.ui_slots(slot:, context:)
      return [] unless slot == "repository.detail"
      return [] if AppSetting.simple?
      return [] if context[:repository].blank?

      [ { id: "throughput.panel", component: "throughput/ThroughputPanel", order: 20 } ]
    end
  end
end
