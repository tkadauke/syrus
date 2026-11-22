module PersonalCalendar
  class FakeAdapter
    class_attribute :events, default: []
    def self.key = :fake
    def self.display_name = "Fake calendar"
    def self.available_for?(context) = context.account.provider == "fake"
    def self.list_events(context)
      return nil unless available_for?(context)

      { "events" => events.map { |event| event.deep_dup } }
    end
    def self.get_event(context)
      return nil unless available_for?(context)

      { "event" => events.find { |event| event.fetch("id").to_s == context.arguments.fetch("event_id").to_s }&.deep_dup }
    end
  end
end
