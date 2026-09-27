module OperatorBriefing
  class Feedback < ApplicationRecord
    self.table_name = "operator_briefing_feedbacks"

    SENTIMENTS = %w[positive negative neutral].freeze

    belongs_to :briefing, class_name: "OperatorBriefing::Briefing", optional: true
    belongs_to :briefing_item, class_name: "OperatorBriefing::BriefingItem", optional: true
    belongs_to :user
    belongs_to :memory_entry, class_name: "AgentMemory::Entry", optional: true

    validates :sentiment, inclusion: { in: SENTIMENTS }, allow_nil: true
    validates :note, length: { maximum: AgentMemory::Entry::CONTENT_MAX_LENGTH }, allow_blank: true
    validates :weight, numericality: { greater_than: 0.0, less_than_or_equal_to: 1.0 }
    validate :has_feedback_content
    validate :targets_briefing_or_item
    validate :briefing_matches_item

    after_create :write_memory_entry!

    private

    def has_feedback_content
      errors.add(:base, "sentiment or note is required") if sentiment.blank? && note.blank?
    end

    def targets_briefing_or_item
      errors.add(:base, "briefing or briefing item is required") if briefing.blank? && briefing_item.blank?
    end

    def briefing_matches_item
      return if briefing.blank? || briefing_item.blank? || briefing_item.briefing_id == briefing.id

      errors.add(:briefing_item, "must belong to the briefing")
    end

    def write_memory_entry!
      memory = InterestSignal.record_feedback!(self)
      update_column(:memory_entry_id, memory.id)
    end
  end
end
