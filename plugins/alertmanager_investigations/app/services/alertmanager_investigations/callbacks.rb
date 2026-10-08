module AlertmanagerInvestigations
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Poller.call
    rescue StandardError => e
      Rails.logger.warn("[AlertmanagerInvestigations] poll failed: #{e.class}: #{e.message}")
    end
  end
end
