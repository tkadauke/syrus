module GitMirror
  # Ticks once a minute while the plugin is enabled.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Sync.run!
    rescue StandardError => e
      # A raising tick is marked failed and retried; the mirror keeps its
      # current registrations until the next one.
      Rails.logger.warn("[GitMirror] sync failed: #{e.class}: #{e.message}")
    end
  end
end
