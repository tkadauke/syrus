module CognitiveEngagementEvents
  class Upsert
    def self.call(**attributes)
      new(**attributes).call
    end

    def initialize(**attributes)
      @attributes = attributes
    end

    def call
      candidate = CognitiveEngagementEvent.new(normalized_attributes)
      candidate.valid?

      event = CognitiveEngagementEvent.find_or_initialize_by(
        repository_id: candidate.repository_id,
        user_id: candidate.user_id,
        source_type: candidate.source_type,
        idempotency_key: candidate.idempotency_key
      )
      event.assign_attributes(candidate.attributes.except("id", "created_at", "updated_at"))
      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :attributes

    def normalized_attributes
      attributes.tap do |attrs|
        attrs[:anchor_kind] ||= "range"
      end
    end
  end
end
