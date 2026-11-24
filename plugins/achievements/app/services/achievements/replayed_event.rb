module Achievements
  # A domain event rebuilt from its serialized form for a retry. Offers the
  # same reading interface (name, payload, occurred_at, []) evaluation uses, so
  # the plugin does not construct core's internal event class.
  ReplayedEvent = Data.define(:name, :payload, :occurred_at) do
    def initialize(name:, payload: {}, occurred_at: nil)
      super(name: name.to_s, payload: (payload || {}).to_h.symbolize_keys.freeze, occurred_at: occurred_at || Time.current)
    end

    def [](key) = payload[key.to_sym]
  end
end
