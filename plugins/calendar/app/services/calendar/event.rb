module Calendar
  Event = Data.define(:source_id, :id, :kind, :title, :starts_at, :ends_at, :actual_started_at,
    :actual_finished_at, :cadence, :destination_path, :state, :metadata) do
    REQUIRED = %i[source_id id kind title starts_at destination_path state].freeze

    def initialize(actual_started_at: nil, actual_finished_at: nil, ends_at: nil, cadence: nil, metadata: {}, **attributes)
      super
      missing = REQUIRED.select { |name| public_send(name).blank? }
      raise ArgumentError, "calendar event missing #{missing.join(', ')}" if missing.any?
      raise ArgumentError, "calendar source_id must be stable and namespaced" unless source_id.match?(/\A[a-z0-9_]+:[a-z0-9_.-]+\z/)
    end

    def as_json(*)
      members.to_h { |name| [ name, serialize(public_send(name)) ] }.compact
    end

    private

    def serialize(value) = value.respond_to?(:iso8601) ? value.iso8601 : value
  end
end
