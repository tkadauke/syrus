module Syrus
  # One thing that happened, addressed by name and described in primitives.
  #
  # Payload values are ids, strings, numbers, booleans, and nested hashes or
  # arrays of the same. Active Record objects are deliberately not allowed:
  # they would couple subscribers to core model internals and would not
  # survive being serialized for async delivery.
  DomainEvent = Data.define(:name, :payload, :occurred_at) do
    def initialize(name:, payload: {}, occurred_at: nil)
      super(name: name.to_s, payload: payload.symbolize_keys.freeze, occurred_at: occurred_at || Time.current)
    end

    def [](key) = payload[key.to_sym]
    def fetch(key, *args) = payload.fetch(key.to_sym, *args)
  end
end
