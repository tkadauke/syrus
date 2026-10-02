module CognitiveReview
  class DiscussionEntry < ApplicationRecord
    self.table_name = "cognitive_review_discussion_entries"

    belongs_to :note, class_name: "CognitiveReview::Note", inverse_of: :discussion_entries
    belongs_to :user, optional: true

    attribute :metadata, :json, default: -> { {} }

    before_validation :normalize_fields

    validates :body, presence: true
    validate :metadata_hash

    scope :ordered, -> { order(:created_at, :id) }

    private

    def normalize_fields
      self.body = body.to_s.strip
      self.metadata = {} unless metadata.is_a?(Hash)
    end

    def metadata_hash
      errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
    end
  end
end
