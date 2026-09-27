module OperatorBriefing
  class BriefingTopicRevision < ApplicationRecord
    self.table_name = "operator_briefing_topic_revisions"

    belongs_to :topic, class_name: "OperatorBriefing::BriefingTopic"
    belongs_to :briefing, class_name: "OperatorBriefing::Briefing", optional: true
    belongs_to :workflow, class_name: "::Workflow", optional: true
    belongs_to :run, optional: true

    validates :revision_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validates :revision_number, uniqueness: { scope: :topic_id }
    validates :generated_at, :narrative, presence: true

    def findings
      Array(super)
    end

    def references
      Array(super)
    end
  end
end
