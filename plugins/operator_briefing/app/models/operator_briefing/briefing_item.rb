module OperatorBriefing
  class BriefingItem < ApplicationRecord
    self.table_name = "operator_briefing_items"

    SEVERITIES = %w[low medium high].freeze

    belongs_to :briefing, class_name: "OperatorBriefing::Briefing", optional: true
    belongs_to :source, polymorphic: true, optional: true

    validates :severity, presence: true, inclusion: { in: SEVERITIES }
    validates :narrative, presence: true
  end
end
