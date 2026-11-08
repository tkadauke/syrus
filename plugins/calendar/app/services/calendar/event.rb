module Calendar
  Event = Data.define(:source_id, :id, :kind, :title, :starts_at, :ends_at, :actual_started_at,
    :actual_finished_at, :estimated_duration_seconds, :duration_estimate_provenance, :cadence,
    :destination_path, :state, :metadata) do
    REQUIRED = %i[source_id id kind title starts_at destination_path state].freeze

    def initialize(actual_started_at: nil, actual_finished_at: nil, ends_at: nil,
      estimated_duration_seconds: nil, duration_estimate_provenance: nil, cadence: nil, metadata: {}, **attributes)
      super
      missing = REQUIRED.select { |name| public_send(name).blank? }
      raise ArgumentError, "calendar event missing #{missing.join(', ')}" if missing.any?
      raise ArgumentError, "calendar source_id must be stable and namespaced" unless source_id.is_a?(String) && source_id.match?(/\A[a-z0-9_]+:[a-z0-9_.-]+\z/)
      raise ArgumentError, "calendar event id must be stable" unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_.:-]+\z/)
      raise ArgumentError, "calendar event kind must be stable" unless kind.is_a?(String) && kind.match?(/\A[a-z0-9_.-]+\z/)
      raise ArgumentError, "calendar title must be text" unless title.is_a?(String)
      raise ArgumentError, "calendar state must be stable" unless state.is_a?(String) && state.match?(/\A[a-z0-9_.-]+\z/)
      raise ArgumentError, "calendar destination_path must be an application path" unless destination_path.to_s.start_with?("/")
      raise ArgumentError, "calendar metadata must be an object" unless metadata.is_a?(Hash)
      validate_time!(:starts_at, starts_at)
      validate_time!(:ends_at, ends_at) if ends_at
      validate_time!(:actual_started_at, actual_started_at) if actual_started_at
      validate_time!(:actual_finished_at, actual_finished_at) if actual_finished_at
      raise ArgumentError, "calendar ends_at must not precede starts_at" if ends_at && ends_at < starts_at
      raise ArgumentError, "calendar actual_finished_at must not precede actual_started_at" if actual_finished_at && actual_started_at && actual_finished_at < actual_started_at
      if estimated_duration_seconds && (!estimated_duration_seconds.is_a?(Numeric) || estimated_duration_seconds <= 0)
        raise ArgumentError, "calendar estimated_duration_seconds must be positive"
      end
      if duration_estimate_provenance && !%w[representative source].include?(duration_estimate_provenance)
        raise ArgumentError, "calendar duration_estimate_provenance must be representative or source"
      end
      if estimated_duration_seconds.present? != duration_estimate_provenance.present?
        raise ArgumentError, "calendar duration estimate and provenance must be supplied together"
      end
      validate_cadence!
    end

    def as_json(*)
      members.to_h { |name| [ name, serialize(public_send(name)) ] }.compact
    end

    private

    def validate_time!(name, value)
      raise ArgumentError, "calendar #{name} must be a timestamp" unless value.respond_to?(:iso8601) && value.respond_to?(:<=>)
    end

    def validate_cadence!
      return unless cadence
      valid = cadence.is_a?(Hash) && cadence[:label].present? && [ true, false ].include?(cadence[:band])
      raise ArgumentError, "calendar cadence must include label and band" unless valid
    end

    def serialize(value) = value.respond_to?(:iso8601) ? value.iso8601 : value
  end
end
