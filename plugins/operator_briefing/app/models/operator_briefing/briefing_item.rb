module OperatorBriefing
  class BriefingItem < ApplicationRecord
    self.table_name = "operator_briefing_items"

    SEVERITIES = OperatorBriefing::SEVERITIES

    belongs_to :briefing, class_name: "OperatorBriefing::Briefing", optional: true
    belongs_to :source, polymorphic: true, optional: true
    has_many :feedbacks, class_name: "OperatorBriefing::Feedback", dependent: :destroy

    validates :severity, presence: true, inclusion: { in: SEVERITIES }
    validates :narrative, presence: true
  end
end
