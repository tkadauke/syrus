module Calendar
  class EventQuery
    MAX_RANGE = 42.days

    def self.call(user:, starts_at:, ends_at:)
      new(user:, starts_at:, ends_at:).call
    end

    def initialize(user:, starts_at:, ends_at:)
      @user = user
      @starts_at = starts_at
      @ends_at = ends_at
    end

    def call
      raise ArgumentError, "starts_at and ends_at are required" unless starts_at && ends_at
      raise ArgumentError, "ends_at must follow starts_at" unless ends_at > starts_at
      raise ArgumentError, "calendar range cannot exceed 42 days" if ends_at - starts_at > MAX_RANGE

      failures = []
      events = Syrus::PluginRegistry.providers_for("calendar:event_source").flat_map do |provider|
        PerformanceLogging.plugin_call(extension_point: "calendar:event_source", provider:, operation: :calendar_events) do
          Array(provider.calendar_events(user:, starts_at:, ends_at:)).map { |event| normalize(event) }
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { calendar_provider: provider.to_s })
        failures << { source: provider.to_s, code: "provider_failed" }
        []
      end
      { events: events.sort_by(&:starts_at).map(&:as_json), failures: }
    end

    private

    attr_reader :user, :starts_at, :ends_at

    def normalize(event) = event.is_a?(Event) ? event : Event.new(**event.symbolize_keys)
  end
end
