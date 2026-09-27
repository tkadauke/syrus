module OperatorBriefing
  class BriefingTopicLink < ApplicationRecord
    self.table_name = "operator_briefing_topic_links"

    belongs_to :topic, class_name: "OperatorBriefing::BriefingTopic"
    belongs_to :briefing, class_name: "OperatorBriefing::Briefing"
    belongs_to :workflow, class_name: "::Workflow", optional: true

    validates :topic_id, uniqueness: { scope: [ :briefing_id, :workflow_id ] }
  end
end
